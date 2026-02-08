#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[preview-db] %s\n' "$*"
}

die() {
  printf '[preview-db] ERROR: %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "Missing required env var: ${name}"
  fi
}

validate_identifier() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    die "${label} has invalid value '${value}'. Use only letters, numbers, and underscores, and do not start with a number."
  fi
}

validate_pr_number() {
  local value="$1"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    die "PR_NUMBER must be a positive integer. Got '${value}'."
  fi
}

qident() {
  # Identifier already validated, so quoting is safe.
  printf '"%s"' "$1"
}

psql_admin() {
  PGPASSWORD="${PGPASSWORD}" psql \
    -v ON_ERROR_STOP=1 \
    -X \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${PGUSER}" \
    -d "${PGDATABASE:-postgres}" \
    "$@"
}

ensure_preview_db() {
  psql_admin \
    -v base_db="${BASE_DB}" \
    -v pr_number="${PR_NUMBER}" \
    -v preview_db="${PREVIEW_DB}" \
    -v source_db="${SOURCE_DB}" <<'SQL'
SELECT pg_advisory_lock(hashtext(:'base_db'), :'pr_number'::integer);

SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = :'preview_db') AS preview_exists \gset
\if :preview_exists
  \echo [preview-db] Preview DB already exists.
\else
  SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = :'source_db') AS source_exists \gset
  \if :source_exists
    SELECT format('CREATE DATABASE %I WITH TEMPLATE %I;', :'preview_db', :'source_db') AS create_sql \gset
    :create_sql
    \echo [preview-db] Preview DB created.
  \else
    \echo [preview-db] ERROR: Source DB :source_db does not exist.
    SELECT 1/0;
  \endif
\endif

SELECT pg_advisory_unlock(hashtext(:'base_db'), :'pr_number'::integer);
SQL

  if [[ -n "${APP_DB_USER:-}" ]]; then
    validate_identifier "${APP_DB_USER}" "APP_DB_USER"
    log "Granting privileges on ${PREVIEW_DB} to ${APP_DB_USER}."
    psql_admin -c "GRANT ALL PRIVILEGES ON DATABASE $(qident "${PREVIEW_DB}") TO $(qident "${APP_DB_USER}");"
  fi
}

drop_preview_db() {
  psql_admin \
    -v base_db="${BASE_DB}" \
    -v pr_number="${PR_NUMBER}" \
    -v preview_db="${PREVIEW_DB}" <<'SQL'
SELECT pg_advisory_lock(hashtext(:'base_db'), :'pr_number'::integer);

SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = :'preview_db') AS preview_exists \gset
\if :preview_exists
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = :'preview_db'
    AND pid <> pg_backend_pid();

  SELECT format('DROP DATABASE IF EXISTS %I;', :'preview_db') AS drop_sql \gset
  :drop_sql
  \echo [preview-db] Preview DB dropped.
\else
  \echo [preview-db] Preview DB does not exist. Nothing to drop.
\endif

SELECT pg_advisory_unlock(hashtext(:'base_db'), :'pr_number'::integer);
SQL
}

main() {
  local command="${1:-}"
  if [[ -z "$command" ]]; then
    die "Usage: $0 <ensure|drop>"
  fi

  require_env "BASE_DB"
  require_env "PR_NUMBER"
  require_env "PGHOST"
  require_env "PGPORT"
  require_env "PGUSER"
  require_env "PGPASSWORD"

  validate_identifier "${BASE_DB}" "BASE_DB"
  validate_pr_number "${PR_NUMBER}"

  SOURCE_DB="${SOURCE_DB:-${TEMPLATE_DB:-${BASE_DB}}}"
  PREVIEW_DB="${PREVIEW_DB:-${BASE_DB}_pr_${PR_NUMBER}}"

  validate_identifier "${SOURCE_DB}" "SOURCE_DB"
  validate_identifier "${PREVIEW_DB}" "PREVIEW_DB"

  case "$command" in
    ensure)
      ensure_preview_db
      ;;
    drop)
      drop_preview_db
      ;;
    *)
      die "Invalid command '${command}'. Use ensure or drop."
      ;;
  esac
}

main "$@"
