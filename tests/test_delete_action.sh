#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/preview-branch.sh"

assert_eq(){ [[ "$1" == "$2" ]] || { printf 'FAIL: %s (expected=%s actual=%s)\n' "$3" "$1" "$2" >&2; exit 1; }; }
assert_contains(){ grep -q -- "$1" "$2" || { printf 'FAIL: %s (missing=%s)\n' "$3" "$1" >&2; exit 1; }; }

setup_mocks() {
  TEST_TMP_DIR="$(mktemp -d)"
  MOCK_BIN_DIR="${TEST_TMP_DIR}/bin"
  MOCK_SQL_DIR="${TEST_TMP_DIR}/sql"
  MOCK_COUNT_FILE="${TEST_TMP_DIR}/psql.count"
  mkdir -p "$MOCK_BIN_DIR" "$MOCK_SQL_DIR"
  printf '0\n' > "$MOCK_COUNT_FILE"

  cat > "$MOCK_BIN_DIR/psql" <<'PSQL'
#!/usr/bin/env bash
set -euo pipefail
count_file="${MOCK_COUNT_FILE:?}"
sql_dir="${MOCK_SQL_DIR:?}"
count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
cat > "${sql_dir}/call_${count}.sql"
PSQL
  chmod +x "$MOCK_BIN_DIR/psql"
}

run_script() {
  PATH="${MOCK_BIN_DIR}:${PATH}" \
  MOCK_COUNT_FILE="$MOCK_COUNT_FILE" \
  MOCK_SQL_DIR="$MOCK_SQL_DIR" \
  BRANCH_NAME="geopark_preview" PGHOST="localhost" PGPORT="5432" PGUSER="postgres" PGPASSWORD="postgres" \
  "$SCRIPT_PATH" delete >/dev/null 2>&1
}

test_delete_runs_drop_sequence() {
  setup_mocks
  run_script
  assert_eq "1" "$(cat "$MOCK_COUNT_FILE")" "delete should call psql once"
  local sql_file="${MOCK_SQL_DIR}/call_1.sql"
  assert_contains "pg_advisory_lock" "$sql_file" "should lock"
  assert_contains "DROP DATABASE IF EXISTS" "$sql_file" "should drop db"
  assert_contains "pg_advisory_unlock" "$sql_file" "should unlock"
}

test_missing_env_fails_before_psql() {
  setup_mocks
  set +e
  PATH="${MOCK_BIN_DIR}:${PATH}" \
  MOCK_COUNT_FILE="$MOCK_COUNT_FILE" \
  MOCK_SQL_DIR="$MOCK_SQL_DIR" \
  PGHOST="localhost" PGPORT="5432" PGUSER="postgres" PGPASSWORD="postgres" \
  "$SCRIPT_PATH" delete >/dev/null 2>&1
  code="$?"
  set -e
  [[ "$code" -ne 0 ]] || { echo "FAIL: missing env should fail" >&2; exit 1; }
  assert_eq "0" "$(cat "$MOCK_COUNT_FILE")" "psql should not run when env invalid"
}

main() {
  test_delete_runs_drop_sequence
  test_missing_env_fails_before_psql
  echo "PASS: delete action tests"
}

main "$@"
