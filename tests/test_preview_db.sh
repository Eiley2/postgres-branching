#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/preview-db.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    printf 'FAIL: %s (expected=%s actual=%s)\n' "${label}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

assert_contains() {
  local needle="$1"
  local haystack_file="$2"
  local label="$3"
  if ! grep -q -- "${needle}" "${haystack_file}"; then
    printf 'FAIL: %s (missing pattern: %s)\n' "${label}" "${needle}" >&2
    exit 1
  fi
}

assert_line_order() {
  local first_pattern="$1"
  local second_pattern="$2"
  local file="$3"
  local label="$4"

  local first_line
  local second_line
  first_line="$(grep -n -- "${first_pattern}" "${file}" | head -n1 | cut -d: -f1)"
  second_line="$(grep -n -- "${second_pattern}" "${file}" | head -n1 | cut -d: -f1)"

  if [[ -z "${first_line}" || -z "${second_line}" || "${first_line}" -ge "${second_line}" ]]; then
    printf 'FAIL: %s (order invalid: %s before %s)\n' "${label}" "${first_pattern}" "${second_pattern}" >&2
    exit 1
  fi
}

setup_mock_psql() {
  TEST_TMP_DIR="$(mktemp -d)"
  MOCK_BIN_DIR="${TEST_TMP_DIR}/bin"
  MOCK_STDIN_DIR="${TEST_TMP_DIR}/stdin"
  MOCK_COUNTER_FILE="${TEST_TMP_DIR}/psql_calls.count"
  mkdir -p "${MOCK_BIN_DIR}" "${MOCK_STDIN_DIR}"
  printf '0\n' > "${MOCK_COUNTER_FILE}"

  cat > "${MOCK_BIN_DIR}/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

counter_file="${MOCK_COUNTER_FILE:?}"
stdin_dir="${MOCK_STDIN_DIR:?}"

count="$(cat "${counter_file}")"
count=$((count + 1))
printf '%s\n' "${count}" > "${counter_file}"
target_file="${stdin_dir}/call_${count}.sql"

args=("$@")
sql_flag_value=""
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "-c" ]] && (( i + 1 < ${#args[@]} )); then
    sql_flag_value="${args[$((i + 1))]}"
    break
  fi
done

if [[ -n "${sql_flag_value}" ]]; then
  printf '%s\n' "${sql_flag_value}" > "${target_file}"
else
  cat > "${target_file}"
fi
EOF
  chmod +x "${MOCK_BIN_DIR}/psql"
}

run_script() {
  local command="$1"
  PATH="${MOCK_BIN_DIR}:${PATH}" \
  MOCK_COUNTER_FILE="${MOCK_COUNTER_FILE}" \
  MOCK_STDIN_DIR="${MOCK_STDIN_DIR}" \
  BASE_DB="geopark" \
  PR_NUMBER="12" \
  PGHOST="localhost" \
  PGPORT="5432" \
  PGUSER="postgres" \
  PGPASSWORD="postgres" \
  "${SCRIPT_PATH}" "${command}" >/dev/null 2>&1
}

test_ensure_holds_lock_in_single_session() {
  setup_mock_psql
  run_script ensure

  assert_eq "1" "$(cat "${MOCK_COUNTER_FILE}")" "ensure should use one psql session"
  local sql_file="${MOCK_STDIN_DIR}/call_1.sql"
  assert_contains "pg_advisory_lock" "${sql_file}" "ensure should acquire advisory lock"
  assert_contains "CREATE DATABASE" "${sql_file}" "ensure should create database from template"
  assert_contains "pg_advisory_unlock" "${sql_file}" "ensure should release advisory lock"
  assert_line_order "pg_advisory_lock" "CREATE DATABASE" "${sql_file}" "ensure lock before create"
  assert_line_order "CREATE DATABASE" "pg_advisory_unlock" "${sql_file}" "ensure unlock after create"
}

test_drop_holds_lock_in_single_session() {
  setup_mock_psql
  run_script drop

  assert_eq "1" "$(cat "${MOCK_COUNTER_FILE}")" "drop should use one psql session"
  local sql_file="${MOCK_STDIN_DIR}/call_1.sql"
  assert_contains "pg_advisory_lock" "${sql_file}" "drop should acquire advisory lock"
  assert_contains "DROP DATABASE IF EXISTS" "${sql_file}" "drop should issue drop statement"
  assert_contains "pg_advisory_unlock" "${sql_file}" "drop should release advisory lock"
  assert_line_order "pg_advisory_lock" "DROP DATABASE IF EXISTS" "${sql_file}" "drop lock before drop"
  assert_line_order "DROP DATABASE IF EXISTS" "pg_advisory_unlock" "${sql_file}" "drop unlock after drop"
}

test_missing_env_fails_before_psql() {
  setup_mock_psql

  set +e
  PATH="${MOCK_BIN_DIR}:${PATH}" \
  MOCK_COUNTER_FILE="${MOCK_COUNTER_FILE}" \
  MOCK_STDIN_DIR="${MOCK_STDIN_DIR}" \
  PR_NUMBER="12" \
  PGHOST="localhost" \
  PGPORT="5432" \
  PGUSER="postgres" \
  PGPASSWORD="postgres" \
  "${SCRIPT_PATH}" ensure >/dev/null 2>&1
  exit_code="$?"
  set -e

  if [[ "${exit_code}" -eq 0 ]]; then
    printf 'FAIL: missing BASE_DB should fail\n' >&2
    exit 1
  fi
  assert_eq "0" "$(cat "${MOCK_COUNTER_FILE}")" "psql should not run when env is invalid"
}

main() {
  test_ensure_holds_lock_in_single_session
  test_drop_holds_lock_in_single_session
  test_missing_env_fails_before_psql
  printf 'PASS: all preview-db tests passed\n'
}

main "$@"
