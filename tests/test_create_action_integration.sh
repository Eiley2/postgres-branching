#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/preview-branch.sh"
PARENT_CONN_PID_1=""
PARENT_CONN_PID_2=""

log_step() {
  printf '[create-integration] %s\n' "$*"
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

assert_no_branch_lock_holder() {
  local context="$1"
  local holder_count
  holder_count="$(
    psql_admin -Atqc "SELECT count(*) FROM pg_locks l
      JOIN pg_stat_activity a ON a.pid = l.pid
      WHERE l.locktype = 'advisory'
        AND l.classid = 20461
        AND l.objid = hashtext('${BRANCH_NAME}')
        AND l.granted
        AND a.query = 'SELECT pg_sleep(86400);';"
  )"
  if [[ "${holder_count}" != "0" ]]; then
    printf 'FAIL: stale lock holder detected (%s)\n' "${context}" >&2
    psql_admin -Atqc "SELECT a.pid, a.application_name, now() - a.query_start AS age, a.query
      FROM pg_locks l
      JOIN pg_stat_activity a ON a.pid = l.pid
      WHERE l.locktype = 'advisory'
        AND l.classid = 20461
        AND l.objid = hashtext('${BRANCH_NAME}')
        AND l.granted;" >&2
    exit 1
  fi
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
}

start_parent_active_connections() {
  log_step "Starting active parent branch sessions to validate clone with concurrent connections"
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

  PARENT_BRANCH="create_parent_ci"
  BRANCH_NAME="create_preview_ci"
  PREVIEW_DB="${BRANCH_NAME}"

  trap cleanup EXIT
  cleanup

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
      INSERT INTO ci_users (id, email) VALUES (1, 'a@example.com'), (2, 'b@example.com');
      INSERT INTO ci_orders (id, user_id, amount) VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30);
    "

  start_parent_active_connections
  log_step "Step 4: executing create action against parent branch with active connections"
  BRANCH_NAME="${BRANCH_NAME}" \
  PARENT_BRANCH="${PARENT_BRANCH}" \
  PGHOST="${PGHOST}" \
  PGPORT="${PGPORT}" \
  PGUSER="${PGUSER}" \
  PGPASSWORD="${PGPASSWORD}" \
  PGDATABASE="${PGDATABASE:-postgres}" \
  "${SCRIPT_PATH}" create
  wait "${PARENT_CONN_PID_1}" || true
  wait "${PARENT_CONN_PID_2}" || true
  assert_no_branch_lock_holder "after first create"

  log_step "Validating preview DB exists"
  exists="$(psql_admin -Atqc "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = '${PREVIEW_DB}');")"
  if [[ "${exists}" != "t" ]]; then
    printf 'FAIL: expected preview db %s to exist\n' "${PREVIEW_DB}" >&2
    exit 1
  fi

  # Step 4: run preview branch tests on the created preview DB.
  run_preview_branch_tests "${PREVIEW_DB}"

  # Step 5: validate replica data matches parent branch.
  log_step "Step 5: validating parent and preview data fingerprints are equal"
  src_users_fp="$(table_fingerprint "${PARENT_BRANCH}" "ci_users")"
  src_orders_fp="$(table_fingerprint "${PARENT_BRANCH}" "ci_orders")"
  pr_users_fp="$(table_fingerprint "${PREVIEW_DB}" "ci_users")"
  pr_orders_fp="$(table_fingerprint "${PREVIEW_DB}" "ci_orders")"
  if [[ "${src_users_fp}" != "${pr_users_fp}" || "${src_orders_fp}" != "${pr_orders_fp}" ]]; then
    printf 'FAIL: data mismatch between source and preview replica\n' >&2
    exit 1
  fi

  log_step "Step 6: executing create action again on existing preview DB (idempotency + lock cleanup check)"
  second_create_output="$(
    BRANCH_NAME="${BRANCH_NAME}" \
    PARENT_BRANCH="${PARENT_BRANCH}" \
    PGHOST="${PGHOST}" \
    PGPORT="${PGPORT}" \
    PGUSER="${PGUSER}" \
    PGPASSWORD="${PGPASSWORD}" \
    PGDATABASE="${PGDATABASE:-postgres}" \
    LOCK_WAIT_TIMEOUT_SEC="30" \
    "${SCRIPT_PATH}" create 2>&1
  )"
  printf '%s\n' "${second_create_output}"
  if ! grep -q "Preview DB already exists. No-op." <<<"${second_create_output}"; then
    printf 'FAIL: second create should be a no-op when preview DB already exists\n' >&2
    exit 1
  fi
  if grep -q "Timed out waiting for operation lock" <<<"${second_create_output}"; then
    printf 'FAIL: second create should not time out waiting for lock\n' >&2
    exit 1
  fi
  assert_no_branch_lock_holder "after second create"

  echo "PASS: create action integration test"
}

main "$@"
