#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/preview-branch.sh"
PARENT_CONN_PID_1=""
PARENT_CONN_PID_2=""

log_step() {
  printf '[reset-integration] %s\n' "$*"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'FAIL: missing required env var %s\n' "${name}" >&2
    exit 1
  fi
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

table_fingerprint() {
  local db="$1"
  local table="$2"
  PGPASSWORD="${PGPASSWORD}" psql \
    -v ON_ERROR_STOP=1 \
    -X \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${PGUSER}" \
    -d "${db}" \
    -Atqc "SELECT md5(COALESCE(string_agg(t::text, '|' ORDER BY t::text), '')) FROM (SELECT * FROM ${table}) t;"
}

run_preview_branch_tests() {
  local db="$1"
  local users
  local orders
  users="$(PGPASSWORD="${PGPASSWORD}" psql -v ON_ERROR_STOP=1 -X -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${db}" -Atqc "SELECT count(*) FROM ci_users;")"
  orders="$(PGPASSWORD="${PGPASSWORD}" psql -v ON_ERROR_STOP=1 -X -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${db}" -Atqc "SELECT count(*) FROM ci_orders;")"
  if [[ "${users}" != "2" || "${orders}" != "3" ]]; then
    printf 'FAIL: preview branch tests failed (users=%s orders=%s)\n' "${users}" "${orders}" >&2
    exit 1
  fi
}

cleanup() {
  set +e
  if [[ -n "${PARENT_CONN_PID_1}" ]]; then
    kill "${PARENT_CONN_PID_1}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PARENT_CONN_PID_2}" ]]; then
    kill "${PARENT_CONN_PID_2}" >/dev/null 2>&1 || true
  fi
  psql_admin -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('${PARENT_BRANCH}','${PREVIEW_DB}') AND pid <> pg_backend_pid();" >/dev/null 2>&1
  psql_admin -c "DROP DATABASE IF EXISTS \"${PREVIEW_DB}\";" >/dev/null 2>&1
  psql_admin -c "DROP DATABASE IF EXISTS \"${PARENT_BRANCH}\";" >/dev/null 2>&1
  psql_admin -c "DROP ROLE IF EXISTS \"${APP_DB_USER}\";" >/dev/null 2>&1
}

start_parent_active_connections() {
  log_step "Starting active parent branch sessions to validate reset with concurrent connections"
  PGPASSWORD="${PGPASSWORD}" psql -v ON_ERROR_STOP=1 -X -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PARENT_BRANCH}" -c "SELECT pg_sleep(8);" >/dev/null &
  PARENT_CONN_PID_1="$!"
  PGPASSWORD="${PGPASSWORD}" psql -v ON_ERROR_STOP=1 -X -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PARENT_BRANCH}" -c "SELECT pg_sleep(8);" >/dev/null &
  PARENT_CONN_PID_2="$!"
}

main() {
  require_env PGHOST
  require_env PGPORT
  require_env PGUSER
  require_env PGPASSWORD

  PARENT_BRANCH="reset_parent_ci"
  BRANCH_NAME="reset_preview_ci"
  PREVIEW_DB="${BRANCH_NAME}"
  APP_DB_USER="preview_app_user_ci_reset"
  APP_DB_USER_PASSWORD="preview_app_user_ci_reset_pw"

  trap cleanup EXIT
  cleanup

  log_step "Step 0: creating app role for grant validation"
  psql_admin -c "CREATE ROLE \"${APP_DB_USER}\" LOGIN PASSWORD '${APP_DB_USER_PASSWORD}';"

  log_step "Step 1: creating source DB"
  psql_admin -c "CREATE DATABASE \"${PARENT_BRANCH}\";"
  log_step "Step 2 and 3: creating tables and seeding source DB"
  PGPASSWORD="${PGPASSWORD}" psql \
    -v ON_ERROR_STOP=1 \
    -X \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${PGUSER}" \
    -d "${PARENT_BRANCH}" \
    -c "
      CREATE TABLE ci_users (id integer primary key, email text not null);
      CREATE TABLE ci_orders (id integer primary key, user_id integer not null references ci_users(id), amount integer not null);
      INSERT INTO ci_users (id, email) VALUES (1, 'new-a@example.com'), (2, 'new-b@example.com');
      INSERT INTO ci_orders (id, user_id, amount) VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30);
    "

  source_users_fp_before="$(table_fingerprint "${PARENT_BRANCH}" "ci_users")"
  source_orders_fp_before="$(table_fingerprint "${PARENT_BRANCH}" "ci_orders")"

  psql_admin -c "CREATE DATABASE \"${PREVIEW_DB}\";"
  PGPASSWORD="${PGPASSWORD}" psql \
    -v ON_ERROR_STOP=1 \
    -X \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${PGUSER}" \
    -d "${PREVIEW_DB}" \
    -c "
      CREATE TABLE ci_users (id integer primary key, email text not null);
      CREATE TABLE ci_orders (id integer primary key, user_id integer not null references ci_users(id), amount integer not null);
      INSERT INTO ci_users (id, email) VALUES (1, 'old-a@example.com'), (2, 'old-b@example.com');
      INSERT INTO ci_orders (id, user_id, amount) VALUES (1, 1, 1), (2, 2, 2), (3, 2, 3);
    "

  stale_preview_users_fp="$(table_fingerprint "${PREVIEW_DB}" "ci_users")"
  if [[ "${stale_preview_users_fp}" == "${source_users_fp_before}" ]]; then
    printf 'FAIL: preview should start stale before reset\n' >&2
    exit 1
  fi

  start_parent_active_connections
  log_step "Step 4: executing reset action against parent branch with active connections"
  BRANCH_NAME="${BRANCH_NAME}" \
  PARENT_BRANCH="${PARENT_BRANCH}" \
  PREVIEW_DB="${PREVIEW_DB}" \
  APP_DB_USER="${APP_DB_USER}" \
  PGHOST="${PGHOST}" \
  PGPORT="${PGPORT}" \
  PGUSER="${PGUSER}" \
  PGPASSWORD="${PGPASSWORD}" \
  PGDATABASE="${PGDATABASE:-postgres}" \
  "${SCRIPT_PATH}" reset
  wait "${PARENT_CONN_PID_1}" || true
  wait "${PARENT_CONN_PID_2}" || true

  # Step 4: execute preview tests after reset.
  log_step "Running preview branch checks after reset"
  run_preview_branch_tests "${PREVIEW_DB}"

  # Step 5: validate preview replica data matches parent branch.
  log_step "Step 5: validating parent and preview data fingerprints are equal"
  reset_preview_users_fp="$(table_fingerprint "${PREVIEW_DB}" "ci_users")"
  reset_preview_orders_fp="$(table_fingerprint "${PREVIEW_DB}" "ci_orders")"
  source_users_fp_after="$(table_fingerprint "${PARENT_BRANCH}" "ci_users")"
  source_orders_fp_after="$(table_fingerprint "${PARENT_BRANCH}" "ci_orders")"
  if [[ "${reset_preview_users_fp}" != "${source_users_fp_after}" || "${reset_preview_orders_fp}" != "${source_orders_fp_after}" ]]; then
    printf 'FAIL: preview data does not match source after reset\n' >&2
    exit 1
  fi

  if [[ "${source_users_fp_before}" != "${source_users_fp_after}" || "${source_orders_fp_before}" != "${source_orders_fp_after}" ]]; then
    printf 'FAIL: source db changed during reset action\n' >&2
    exit 1
  fi

  log_step "Step 6: validating APP_DB_USER grants and default privileges after reset"
  preview_users_as_app="$(
    PGPASSWORD="${APP_DB_USER_PASSWORD}" psql -v ON_ERROR_STOP=1 -X -h "${PGHOST}" -p "${PGPORT}" -U "${APP_DB_USER}" -d "${PREVIEW_DB}" -Atqc "SELECT count(*) FROM ci_users;"
  )"
  if [[ "${preview_users_as_app}" != "2" ]]; then
    printf 'FAIL: app user should be able to read reset preview data (users=%s)\n' "${preview_users_as_app}" >&2
    exit 1
  fi
  PGPASSWORD="${APP_DB_USER_PASSWORD}" psql -v ON_ERROR_STOP=1 -X -h "${PGHOST}" -p "${PGPORT}" -U "${APP_DB_USER}" -d "${PREVIEW_DB}" \
    -c "INSERT INTO ci_users (id, email) VALUES (100, 'grant-reset@example.com');"
  PGPASSWORD="${PGPASSWORD}" psql -v ON_ERROR_STOP=1 -X -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PREVIEW_DB}" \
    -c "
      DROP TABLE IF EXISTS ci_grant_default_reset;
      DROP SEQUENCE IF EXISTS ci_grant_default_reset_seq;
      CREATE TABLE ci_grant_default_reset (id integer primary key, note text not null);
      CREATE SEQUENCE ci_grant_default_reset_seq START 1;
    "
  PGPASSWORD="${APP_DB_USER_PASSWORD}" psql -v ON_ERROR_STOP=1 -X -h "${PGHOST}" -p "${PGPORT}" -U "${APP_DB_USER}" -d "${PREVIEW_DB}" \
    -c "
      INSERT INTO ci_grant_default_reset (id, note) VALUES (1, 'ok');
      SELECT nextval('ci_grant_default_reset_seq');
    " >/dev/null

  echo "PASS: reset action integration test"
}

main "$@"
