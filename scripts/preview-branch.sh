#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

LABEL="preview-branch"

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
  command -v docker >/dev/null 2>&1 \
    || die "Local pg_dump is incompatible and docker is not available."
  PGPASSWORD="${PGPASSWORD}" \
  PARENT_BRANCH="${PARENT_BRANCH}" \
  PREVIEW_DB="${PREVIEW_DB}" \
  docker run --rm --network host \
    -e PGPASSWORD -e PGHOST -e PGPORT -e PGUSER -e PARENT_BRANCH -e PREVIEW_DB \
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
  local server_major local_major
  server_major="$(extract_server_major "${server_version_num}" || true)"
  local_major="$(extract_local_pg_dump_major || true)"

  if [[ -n "${server_major}" && "${local_major:-unknown}" != "${server_major}" ]]; then
    log "Local pg_dump ${local_major:-unknown} does not match server ${server_major}; using Docker postgres:${server_major} client."
    clone_from_source_docker "${server_major}"
  else
    clone_from_source_local
  fi
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
    validate_identifier "${APP_DB_USER}" APP_DB_USER
    log "Granting privileges on ${PREVIEW_DB} to ${APP_DB_USER}."
    psql_admin -c "GRANT ALL PRIVILEGES ON DATABASE $(qident "${PREVIEW_DB}") TO $(qident "${APP_DB_USER}");"
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
  PREVIEW_DB="${BRANCH_NAME}"

  LABEL="${command}-branch"

  case "$command" in
    create) cmd_create ;;
    delete) cmd_delete ;;
    reset)  cmd_reset  ;;
    *)      die "Invalid command '${command}'. Use create, delete, or reset." ;;
  esac
}

main "$@"
