#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/preview-branch.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s (expected=%s actual=%s)\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local pattern="$1" file="$2" label="$3"
  if ! grep -q -- "$pattern" "$file"; then
    printf 'FAIL: %s (missing=%s)\n' "$label" "$pattern" >&2
    exit 1
  fi
}

assert_not_exists() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then
    printf 'FAIL: %s (unexpected file=%s)\n' "$label" "$file" >&2
    exit 1
  fi
}

setup_mocks() {
  TEST_TMP_DIR="$(mktemp -d)"
  MOCK_BIN_DIR="${TEST_TMP_DIR}/bin"
  MOCK_SQL_DIR="${TEST_TMP_DIR}/sql"
  MOCK_LOG_DIR="${TEST_TMP_DIR}/logs"
  MOCK_COUNT_FILE="${TEST_TMP_DIR}/psql.count"
  mkdir -p "$MOCK_BIN_DIR" "$MOCK_SQL_DIR" "$MOCK_LOG_DIR"
  printf '0\n' > "$MOCK_COUNT_FILE"

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
  MOCK_PSQL_STDOUT=""
  MOCK_PG_DUMP_VERSION="pg_dump (PostgreSQL) 18.1"
}

run_script() {
  PATH="${MOCK_BIN_DIR}:${PATH}" \
  MOCK_COUNT_FILE="$MOCK_COUNT_FILE" \
  MOCK_SQL_DIR="$MOCK_SQL_DIR" \
  MOCK_LOG_DIR="$MOCK_LOG_DIR" \
  MOCK_PSQL_STDOUT="${MOCK_PSQL_STDOUT:-}" \
  MOCK_PG_DUMP_VERSION="${MOCK_PG_DUMP_VERSION:-}" \
  BRANCH_NAME="geopark_preview" \
  PARENT_BRANCH="geopark" \
  PGHOST="localhost" \
  PGPORT="5432" \
  PGUSER="postgres" \
  PGPASSWORD="postgres" \
  "$SCRIPT_PATH" create >/dev/null 2>&1
}

test_create_runs_local_clone_when_major_matches() {
  setup_mocks
  MOCK_PSQL_STDOUT=$'SERVER_VERSION_NUM=180001\nPREVIEW_CREATED=1'
  run_script
  assert_eq "1" "$(cat "$MOCK_COUNT_FILE")" "create should use one psql session"
  local sql_file="${MOCK_SQL_DIR}/call_1.sql"
  assert_contains "pg_advisory_lock" "$sql_file" "should acquire lock"
  assert_contains "CREATE DATABASE" "$sql_file" "should create preview db"
  assert_contains "pg_advisory_unlock" "$sql_file" "should release lock"
  assert_contains "-d geopark" "${MOCK_LOG_DIR}/pg_dump.args" "should dump from source"
  assert_contains "-d geopark_preview" "${MOCK_LOG_DIR}/pg_restore.args" "should restore into preview"
  assert_not_exists "${MOCK_LOG_DIR}/docker.args" "matching major should not use docker"
}

test_create_uses_docker_on_major_mismatch() {
  setup_mocks
  MOCK_PSQL_STDOUT=$'SERVER_VERSION_NUM=160010\nPREVIEW_CREATED=1'
  MOCK_PG_DUMP_VERSION='pg_dump (PostgreSQL) 18.1'
  run_script
  assert_contains "postgres:16" "${MOCK_LOG_DIR}/docker.args" "mismatch should use postgres:16 docker client"
  assert_not_exists "${MOCK_LOG_DIR}/pg_dump.args" "mismatch should skip local clone"
  assert_not_exists "${MOCK_LOG_DIR}/pg_restore.args" "mismatch should skip local restore"
}

test_create_is_noop_when_exists() {
  setup_mocks
  MOCK_PSQL_STDOUT=$'SERVER_VERSION_NUM=180001\nALREADY_EXISTS=1'
  run_script
  assert_eq "1" "$(cat "$MOCK_COUNT_FILE")" "noop should still call psql once"
  assert_not_exists "${MOCK_LOG_DIR}/pg_dump.args" "noop should not run pg_dump"
  assert_not_exists "${MOCK_LOG_DIR}/pg_restore.args" "noop should not run pg_restore"
  assert_not_exists "${MOCK_LOG_DIR}/docker.args" "noop should not run docker"
}

test_missing_env_fails_before_psql() {
  setup_mocks
  set +e
  PATH="${MOCK_BIN_DIR}:${PATH}" \
  MOCK_COUNT_FILE="$MOCK_COUNT_FILE" \
  MOCK_SQL_DIR="$MOCK_SQL_DIR" \
  MOCK_LOG_DIR="$MOCK_LOG_DIR" \
  PARENT_BRANCH="geopark" PGHOST="localhost" PGPORT="5432" PGUSER="postgres" PGPASSWORD="postgres" \
  "$SCRIPT_PATH" create >/dev/null 2>&1
  code="$?"
  set -e
  [[ "$code" -ne 0 ]] || { echo "FAIL: missing env should fail" >&2; exit 1; }
  assert_eq "0" "$(cat "$MOCK_COUNT_FILE")" "psql should not run when env invalid"
}

main() {
  test_create_runs_local_clone_when_major_matches
  test_create_uses_docker_on_major_mismatch
  test_create_is_noop_when_exists
  test_missing_env_fails_before_psql
  echo "PASS: create action tests"
}

main "$@"
