#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

LABEL="preview-branch"
LOCK_NAMESPACE=20461
LOCK_HOLDER_PID=""
LOCK_READY_FILE=""
LOCK_LOG_FILE=""

log() { printf '[%s] %s\n' "${LABEL}" "$*"; }
die() { printf '[%s] ERROR: %s\n' "${LABEL}" "$*" >&2; exit 1; }

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Missing required env var: ${name}"
}

validate_identifier() {
  local value="$1" label="$2"
  [[ "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] \
    || die "${label} has invalid value '${value}'. Use only letters, numbers, and underscores."
}

qident() { printf '"%s"' "$1"; }

validate_clone_strategy() {
  case "${CLONE_STRATEGY:-auto}" in
    auto|local|docker) ;;
    *) die "Invalid CLONE_STRATEGY '${CLONE_STRATEGY}'. Use auto, local, or docker." ;;
  esac
}

validate_lock_strategy() {
  case "${LOCK_STRATEGY:-advisory}" in
    advisory|none) ;;
    *) die "Invalid LOCK_STRATEGY '${LOCK_STRATEGY}'. Use advisory or none." ;;
  esac
}

load_env_file_if_present() {
  if [[ -n "${ENV_FILE:-}" ]]; then
    [[ -f "${ENV_FILE}" ]] || die "ENV_FILE was set but file does not exist: ${ENV_FILE}"
    # shellcheck disable=SC1090
    set -a; . "${ENV_FILE}"; set +a
  fi
}

psql_admin() {
  PGPASSWORD="${PGPASSWORD}" psql \
    -v ON_ERROR_STOP=1 -X -q \
    -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" \
    -d "${PGDATABASE:-postgres}" "$@"
}

psql_preview() {
  PGPASSWORD="${PGPASSWORD}" psql \
    -v ON_ERROR_STOP=1 -X -q \
    -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" \
    -d "${PREVIEW_DB}" "$@"
}

cleanup_lock_resources() {
  [[ -n "${LOCK_READY_FILE:-}" ]] && rm -f "${LOCK_READY_FILE}" || true
  [[ -n "${LOCK_LOG_FILE:-}" ]] && rm -f "${LOCK_LOG_FILE}" || true
  LOCK_READY_FILE=""
  LOCK_LOG_FILE=""
}

release_branch_lock() {
  if [[ -n "${LOCK_HOLDER_PID:-}" ]]; then
    kill "${LOCK_HOLDER_PID}" >/dev/null 2>&1 || true
    wait "${LOCK_HOLDER_PID}" >/dev/null 2>&1 || true
    LOCK_HOLDER_PID=""
  fi
  cleanup_lock_resources
}

acquire_branch_lock() {
  local lock_strategy="${LOCK_STRATEGY:-advisory}"
  [[ "${lock_strategy}" == "advisory" ]] || return 0

  local timeout="${LOCK_WAIT_TIMEOUT_SEC:-300}"
  [[ "${timeout}" =~ ^[0-9]+$ ]] || die "LOCK_WAIT_TIMEOUT_SEC must be an integer (seconds)."

  LOCK_READY_FILE="$(mktemp)"
  LOCK_LOG_FILE="$(mktemp)"

  psql_admin \
    -v branch_name="${BRANCH_NAME}" \
    -v lock_namespace="${LOCK_NAMESPACE}" \
    -v ready_file="${LOCK_READY_FILE}" <<'SQL' >"${LOCK_LOG_FILE}" 2>&1 &
SELECT pg_advisory_lock(:lock_namespace, hashtext(:'branch_name'));
\o :ready_file
\echo LOCK_ACQUIRED
\o
SELECT pg_sleep(86400);
SQL
  LOCK_HOLDER_PID=$!

  local waited=0
  while true; do
    if [[ -f "${LOCK_READY_FILE}" ]] && grep -q '^LOCK_ACQUIRED$' "${LOCK_READY_FILE}"; then
      log "Operation lock acquired for ${BRANCH_NAME}."
      return 0
    fi
    if ! kill -0 "${LOCK_HOLDER_PID}" >/dev/null 2>&1; then
      local lock_err=""
      if [[ -f "${LOCK_LOG_FILE}" ]]; then
        lock_err="$(tail -n 20 "${LOCK_LOG_FILE}" | tr '\n' ' ')"
      fi
      release_branch_lock
      die "Failed to acquire operation lock for ${BRANCH_NAME}. ${lock_err}"
    fi
    if (( waited >= timeout )); then
      release_branch_lock
      die "Timed out waiting for operation lock for ${BRANCH_NAME} after ${timeout}s."
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

# ---------------------------------------------------------------------------
# Clone infrastructure (shared by create & reset)
# ---------------------------------------------------------------------------

extract_server_major() {
  local version_num="${1:-}"
  [[ "${version_num}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$(( version_num / 10000 ))"
}

extract_local_pg_dump_major() {
  command -v pg_dump >/dev/null 2>&1 || return 1
  pg_dump --version 2>/dev/null | sed -nE 's/.* ([0-9]+)(\.[0-9]+)?.*/\1/p' | head -n1
}

clone_from_source_local() {
  command -v pg_dump    >/dev/null 2>&1 || die "Required command not found: pg_dump"
  command -v pg_restore >/dev/null 2>&1 || die "Required command not found: pg_restore"
  PGPASSWORD="${PGPASSWORD}" pg_dump \
    -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PARENT_BRANCH}" \
    --format=custom --no-owner --no-acl \
  | PGPASSWORD="${PGPASSWORD}" pg_restore \
    -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PREVIEW_DB}" \
    --no-owner --no-acl --clean --if-exists --exit-on-error
}

clone_from_source_docker() {
  local server_major="$1"
  local docker_pghost="${PGHOST}"
  local -a docker_network_args=()
  local -a docker_mount_args=()
  local -a docker_env_args=(-e PGPASSWORD -e PGHOST -e PGPORT -e PGUSER -e PARENT_BRANCH -e PREVIEW_DB)
  local env_name cert_var cert_path

  command -v docker >/dev/null 2>&1 \
    || die "Local pg_dump is incompatible and docker is not available."

  if [[ "${PGHOST}" == "127.0.0.1" || "${PGHOST}" == "localhost" ]]; then
    docker_pghost="host.docker.internal"
    docker_network_args+=(--add-host host.docker.internal:host-gateway)
  fi

  for env_name in PGAPPNAME PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY PGSSLCRL PGSSLCRLDIR PGCHANNELBINDING PGTARGETSESSIONATTRS PGCONNECT_TIMEOUT PGOPTIONS; do
    if [[ -n "${!env_name:-}" ]]; then
      docker_env_args+=(-e "${env_name}")
    fi
  done

  for cert_var in PGSSLROOTCERT PGSSLCERT PGSSLKEY PGSSLCRL; do
    cert_path="${!cert_var:-}"
    if [[ -n "${cert_path}" ]]; then
      [[ -f "${cert_path}" ]] || die "${cert_var} points to a missing file: ${cert_path}"
      docker_mount_args+=(-v "${cert_path}:${cert_path}:ro")
    fi
  done
  if [[ -n "${PGSSLCRLDIR:-}" ]]; then
    [[ -d "${PGSSLCRLDIR}" ]] || die "PGSSLCRLDIR points to a missing directory: ${PGSSLCRLDIR}"
    docker_mount_args+=(-v "${PGSSLCRLDIR}:${PGSSLCRLDIR}:ro")
  fi

  PGPASSWORD="${PGPASSWORD}" \
  PGHOST="${docker_pghost}" \
  PARENT_BRANCH="${PARENT_BRANCH}" \
  PREVIEW_DB="${PREVIEW_DB}" \
  docker run --rm \
    "${docker_network_args[@]}" \
    "${docker_mount_args[@]}" \
    "${docker_env_args[@]}" \
    "postgres:${server_major}" \
    bash -euo pipefail -c '
      pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PARENT_BRANCH" \
        --format=custom --no-owner --no-acl \
      | pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PREVIEW_DB" \
        --no-owner --no-acl --clean --if-exists --exit-on-error
    '
}

clone_from_source() {
  local server_version_num="$1"
  local server_major local_major clone_strategy
  clone_strategy="${CLONE_STRATEGY:-auto}"
  server_major="$(extract_server_major "${server_version_num}" || true)"
  local_major="$(extract_local_pg_dump_major || true)"

  case "${clone_strategy}" in
    local)
      clone_from_source_local
      ;;
    docker)
      [[ -n "${server_major}" ]] || die "Unable to detect server major version required for docker clone strategy."
      log "Clone strategy is docker; using postgres:${server_major} client."
      clone_from_source_docker "${server_major}"
      ;;
    auto)
      if [[ -n "${server_major}" && "${local_major:-unknown}" != "${server_major}" ]]; then
        log "Local pg_dump ${local_major:-unknown} does not match server ${server_major}; using Docker postgres:${server_major} client."
        clone_from_source_docker "${server_major}"
      else
        clone_from_source_local
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Drop helper (shared by all three commands as cleanup / main logic)
# ---------------------------------------------------------------------------

drop_preview_db() {
  psql_admin -v branch_name="${BRANCH_NAME}" -v preview_db="${PREVIEW_DB}" <<'SQL'
SELECT pg_advisory_lock(hashtext(:'branch_name'));
SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = :'preview_db') AS preview_exists \gset
\if :preview_exists
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = :'preview_db'
    AND pid <> pg_backend_pid();
  SELECT format('DROP DATABASE IF EXISTS %I;', :'preview_db') AS drop_sql \gset
  :drop_sql
\endif
SELECT pg_advisory_unlock(hashtext(:'branch_name'));
SQL
}

# ---------------------------------------------------------------------------
# Grant helper (shared by create & reset)
# ---------------------------------------------------------------------------

grant_app_user() {
  if [[ -n "${APP_DB_USER:-}" ]]; then
    local app_user_ident
    validate_identifier "${APP_DB_USER}" APP_DB_USER
    app_user_ident="$(qident "${APP_DB_USER}")"

    log "Granting database and schema privileges on ${PREVIEW_DB} to ${APP_DB_USER}."
    psql_admin -c "GRANT ALL PRIVILEGES ON DATABASE $(qident "${PREVIEW_DB}") TO ${app_user_ident};"
    psql_preview <<SQL
DO \$\$
DECLARE
  schema_name text;
BEGIN
  FOR schema_name IN
    SELECT nspname
    FROM pg_namespace
    WHERE nspname NOT IN ('pg_catalog', 'information_schema')
      AND nspname NOT LIKE 'pg_toast%'
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %s', schema_name, '${app_user_ident}');
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I TO %s', schema_name, '${app_user_ident}');
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I TO %s', schema_name, '${app_user_ident}');
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL PRIVILEGES ON TABLES TO %s', schema_name, '${app_user_ident}');
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL PRIVILEGES ON SEQUENCES TO %s', schema_name, '${app_user_ident}');
  END LOOP;
END
\$\$;
SQL
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_create() {
  require_env PARENT_BRANCH
  validate_identifier "${PARENT_BRANCH}" PARENT_BRANCH

  local setup_output
  setup_output="$(
    psql_admin \
      -v branch_name="${BRANCH_NAME}" \
      -v preview_db="${PREVIEW_DB}" \
      -v parent_branch="${PARENT_BRANCH}" <<'SQL'
SELECT current_setting('server_version_num') AS server_version_num \gset
\echo SERVER_VERSION_NUM=:server_version_num
SELECT pg_advisory_lock(hashtext(:'branch_name'));

SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = :'preview_db') AS preview_exists \gset
\if :preview_exists
  \echo ALREADY_EXISTS=1
\else
  SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = :'parent_branch') AS parent_exists \gset
  \if :parent_exists
    SELECT format('CREATE DATABASE %I;', :'preview_db') AS create_sql \gset
    :create_sql
    \echo PREVIEW_CREATED=1
  \else
    \echo PARENT_MISSING=1
    SELECT 1/0;
  \endif
\endif

SELECT pg_advisory_unlock(hashtext(:'branch_name'));
SQL
  )"
  printf '%s\n' "$setup_output"

  if printf '%s\n' "$setup_output" | grep -q 'ALREADY_EXISTS=1'; then
    log "Preview DB already exists. No-op."
    return 0
  fi

  local server_version_num
  server_version_num="$(printf '%s\n' "$setup_output" | sed -n 's/^SERVER_VERSION_NUM=//p' | head -n1)"

  if printf '%s\n' "$setup_output" | grep -q 'PREVIEW_CREATED=1'; then
    if ! clone_from_source "${server_version_num}"; then
      log "Clone failed. Cleaning up incomplete preview DB."
      drop_preview_db || true
      die "Failed to clone data from parent branch ${PARENT_BRANCH}."
    fi
    log "Preview DB created and restored from parent branch."
  fi

  grant_app_user
}

cmd_delete() {
  psql_admin -v branch_name="${BRANCH_NAME}" -v preview_db="${PREVIEW_DB}" <<'SQL'
SELECT pg_advisory_lock(hashtext(:'branch_name'));

SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = :'preview_db') AS preview_exists \gset
\if :preview_exists
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = :'preview_db'
    AND pid <> pg_backend_pid();
  SELECT format('DROP DATABASE IF EXISTS %I;', :'preview_db') AS drop_sql \gset
  :drop_sql
  \echo [preview-branch] Preview DB dropped.
\else
  \echo [preview-branch] Preview DB does not exist. Nothing to delete.
\endif

SELECT pg_advisory_unlock(hashtext(:'branch_name'));
SQL
}

cmd_reset() {
  require_env PARENT_BRANCH
  validate_identifier "${PARENT_BRANCH}" PARENT_BRANCH

  local setup_output
  setup_output="$(
    psql_admin \
      -v branch_name="${BRANCH_NAME}" \
      -v preview_db="${PREVIEW_DB}" \
      -v parent_branch="${PARENT_BRANCH}" <<'SQL'
SELECT current_setting('server_version_num') AS server_version_num \gset
\echo SERVER_VERSION_NUM=:server_version_num
SELECT pg_advisory_lock(hashtext(:'branch_name'));

SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = :'parent_branch') AS parent_exists \gset
\if :parent_exists
  SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = :'preview_db') AS preview_exists \gset
  \if :preview_exists
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = :'preview_db'
      AND pid <> pg_backend_pid();
    SELECT format('DROP DATABASE IF EXISTS %I;', :'preview_db') AS drop_sql \gset
    :drop_sql
  \endif
  SELECT format('CREATE DATABASE %I;', :'preview_db') AS create_sql \gset
  :create_sql
  \echo PREVIEW_RESET=1
\else
  \echo PARENT_MISSING=1
  SELECT 1/0;
\endif

SELECT pg_advisory_unlock(hashtext(:'branch_name'));
SQL
  )"
  printf '%s\n' "$setup_output"

  local server_version_num
  server_version_num="$(printf '%s\n' "$setup_output" | sed -n 's/^SERVER_VERSION_NUM=//p' | head -n1)"

  if printf '%s\n' "$setup_output" | grep -q 'PREVIEW_RESET=1'; then
    if ! clone_from_source "${server_version_num}"; then
      log "Restore failed. Cleaning up incomplete preview DB."
      drop_preview_db || true
      die "Failed to restore preview DB from parent branch ${PARENT_BRANCH}."
    fi
    log "Preview DB reset from parent branch."
  fi

  grant_app_user
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  load_env_file_if_present

  local command="${1:-}"
  [[ -n "$command" ]] || die "Usage: $0 <create|delete|reset>"

  require_env BRANCH_NAME
  require_env PGHOST
  require_env PGPORT
  require_env PGUSER
  require_env PGPASSWORD

  validate_identifier "${BRANCH_NAME}" BRANCH_NAME
  validate_clone_strategy
  validate_lock_strategy
  PREVIEW_DB="${BRANCH_NAME}"

  LABEL="${command}-branch"
  trap release_branch_lock EXIT

  case "$command" in
    create) acquire_branch_lock; cmd_create ;;
    delete) acquire_branch_lock; cmd_delete ;;
    reset)  acquire_branch_lock; cmd_reset  ;;
    *)      die "Invalid command '${command}'. Use create, delete, or reset." ;;
  esac
}

main "$@"
