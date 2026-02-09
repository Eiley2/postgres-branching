#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/preview-branch.sh"

assert_eq(){ [[ "$1" == "$2" ]] || { printf 'FAIL: %s (expected=%s actual=%s)\n' "$3" "$1" "$2" >&2; exit 1; }; }
assert_contains(){ grep -q -- "$1" "$2" || { printf 'FAIL: %s (missing=%s)\n' "$3" "$1" >&2; exit 1; }; }
assert_not_exists(){ [[ ! -f "$1" ]] || { printf 'FAIL: %s (unexpected file=%s)\n' "$2" "$1" >&2; exit 1; }; }

setup_mocks() {
  TEST_TMP_DIR="$(mktemp -d)"
  MOCK_BIN_DIR="${TEST_TMP_DIR}/bin"
  MOCK_SQL_DIR="${TEST_TMP_DIR}/sql"
  MOCK_LOG_DIR="${TEST_TMP_DIR}/logs"
  MOCK_COUNT_FILE="${TEST_TMP_DIR}/psql.count"
  mkdir -p "$MOCK_BIN_DIR" "$MOCK_SQL_DIR" "$MOCK_LOG_DIR"
  printf '0\n' > "$MOCK_COUNT_FILE"
  MOCK_PSQL_STDOUT=""

cat > "$MOCK_BIN_DIR/psql" <<'PSQL'
#!/usr/bin/env bash
set -euo pipefail
count_file="${MOCK_COUNT_FILE:?}"
sql_dir="${MOCK_SQL_DIR:?}"
count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
out="${sql_dir}/call_${count}.sql"
args=("$@")
sql_flag=""
for ((i=0;i<${#args[@]};i++)); do
  if [[ "${args[$i]}" == "-c" ]] && (( i + 1 < ${#args[@]} )); then
    sql_flag="${args[$((i + 1))]}"
    break
  fi
done
if [[ -n "$sql_flag" ]]; then
  printf '%s\n' "$sql_flag" > "$out"
else
  cat > "$out"
fi
if [[ -n "${MOCK_PSQL_STDOUT:-}" ]]; then
  printf '%s\n' "$MOCK_PSQL_STDOUT"
fi
PSQL

  cat > "$MOCK_BIN_DIR/pg_dump" <<'PGD'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "${MOCK_PG_DUMP_VERSION:-pg_dump (PostgreSQL) 18.1}"
  exit 0
fi
printf '%s\n' "$*" > "${MOCK_LOG_DIR:?}/pg_dump.args"
printf 'DUMP_STREAM\n'
PGD

  cat > "$MOCK_BIN_DIR/pg_restore" <<'PGR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${MOCK_LOG_DIR:?}/pg_restore.args"
cat >/dev/null
PGR

  cat > "$MOCK_BIN_DIR/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${MOCK_LOG_DIR:?}/docker.args"
DOCKER

  chmod +x "$MOCK_BIN_DIR/psql" "$MOCK_BIN_DIR/pg_dump" "$MOCK_BIN_DIR/pg_restore" "$MOCK_BIN_DIR/docker"
  MOCK_PG_DUMP_VERSION="pg_dump (PostgreSQL) 18.1"
}

run_script() {
  PATH="${MOCK_BIN_DIR}:${PATH}" \
  MOCK_COUNT_FILE="$MOCK_COUNT_FILE" \
  MOCK_SQL_DIR="$MOCK_SQL_DIR" \
  MOCK_LOG_DIR="$MOCK_LOG_DIR" \
  MOCK_PSQL_STDOUT="${MOCK_PSQL_STDOUT:-}" \
  MOCK_PG_DUMP_VERSION="${MOCK_PG_DUMP_VERSION:-}" \
  CLONE_STRATEGY="${CLONE_STRATEGY:-auto}" \
  LOCK_STRATEGY="${LOCK_STRATEGY:-none}" \
  APP_DB_USER="${APP_DB_USER:-}" \
  BRANCH_NAME="geopark_preview" PARENT_BRANCH="geopark" PGHOST="localhost" PGPORT="5432" PGUSER="postgres" PGPASSWORD="postgres" \
  "$SCRIPT_PATH" reset >/dev/null 2>&1
}

test_reset_recreates_and_restores_local() {
  setup_mocks
  MOCK_PSQL_STDOUT=$'SERVER_VERSION_NUM=180001\nPREVIEW_RESET=1'
  run_script
  assert_eq "1" "$(cat "$MOCK_COUNT_FILE")" "reset should call psql once"
  local sql_file="${MOCK_SQL_DIR}/call_1.sql"
  assert_contains "pg_advisory_lock" "$sql_file" "should lock"
  assert_contains "DROP DATABASE IF EXISTS" "$sql_file" "should drop preview"
  assert_contains "CREATE DATABASE" "$sql_file" "should recreate preview"
  assert_contains "pg_advisory_unlock" "$sql_file" "should unlock"
  assert_contains "-d geopark" "${MOCK_LOG_DIR}/pg_dump.args" "should dump from source"
  assert_contains "-d geopark_preview" "${MOCK_LOG_DIR}/pg_restore.args" "should restore into preview"
  assert_not_exists "${MOCK_LOG_DIR}/docker.args" "matching major should not use docker"
}

test_reset_uses_docker_on_major_mismatch() {
  setup_mocks
  MOCK_PSQL_STDOUT=$'SERVER_VERSION_NUM=160010\nPREVIEW_RESET=1'
  run_script
  assert_contains "postgres:16" "${MOCK_LOG_DIR}/docker.args" "mismatch should use postgres:16 docker client"
  assert_not_exists "${MOCK_LOG_DIR}/pg_dump.args" "mismatch should skip local dump"
  assert_not_exists "${MOCK_LOG_DIR}/pg_restore.args" "mismatch should skip local restore"
}

test_reset_honors_local_clone_strategy() {
  setup_mocks
  MOCK_PSQL_STDOUT=$'SERVER_VERSION_NUM=160010\nPREVIEW_RESET=1'
  CLONE_STRATEGY="local"
  run_script
  assert_contains "-d geopark" "${MOCK_LOG_DIR}/pg_dump.args" "local strategy should run pg_dump"
  assert_contains "-d geopark_preview" "${MOCK_LOG_DIR}/pg_restore.args" "local strategy should run pg_restore"
  assert_not_exists "${MOCK_LOG_DIR}/docker.args" "local strategy should not use docker"
}

test_reset_grants_app_user_access() {
  setup_mocks
  MOCK_PSQL_STDOUT=$'SERVER_VERSION_NUM=180001\nPREVIEW_RESET=1'
  APP_DB_USER="preview_user"
  run_script
  assert_eq "3" "$(cat "$MOCK_COUNT_FILE")" "grant flow should add two psql calls"
  assert_contains "GRANT ALL PRIVILEGES ON DATABASE" "${MOCK_SQL_DIR}/call_2.sql" "should grant database privileges"
  assert_contains "GRANT USAGE ON SCHEMA" "${MOCK_SQL_DIR}/call_3.sql" "should grant schema usage"
  assert_contains "ALTER DEFAULT PRIVILEGES" "${MOCK_SQL_DIR}/call_3.sql" "should grant default privileges"
}

test_missing_env_fails_before_psql() {
  setup_mocks
  set +e
  PATH="${MOCK_BIN_DIR}:${PATH}" \
  MOCK_COUNT_FILE="$MOCK_COUNT_FILE" \
  MOCK_SQL_DIR="$MOCK_SQL_DIR" \
  MOCK_LOG_DIR="$MOCK_LOG_DIR" \
  LOCK_STRATEGY="none" \
  PARENT_BRANCH="geopark" PGHOST="localhost" PGPORT="5432" PGUSER="postgres" PGPASSWORD="postgres" \
  "$SCRIPT_PATH" reset >/dev/null 2>&1
  code="$?"
  set -e
  [[ "$code" -ne 0 ]] || { echo "FAIL: missing env should fail" >&2; exit 1; }
  assert_eq "0" "$(cat "$MOCK_COUNT_FILE")" "psql should not run when env invalid"
}

main() {
  test_reset_recreates_and_restores_local
  test_reset_uses_docker_on_major_mismatch
  test_reset_honors_local_clone_strategy
  test_reset_grants_app_user_access
  test_missing_env_fails_before_psql
  echo "PASS: reset action tests"
}

main "$@"
