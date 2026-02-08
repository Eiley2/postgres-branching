#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/preview-db.sh"
VERBOSE="${VERBOSE:-0}"
SOURCE_CONN_COUNT="${SOURCE_CONN_COUNT:-2}"
SOURCE_CONN_SLEEP_SECONDS="${SOURCE_CONN_SLEEP_SECONDS:-180}"
SOURCE_CONN_PIDS=()

info() {
  printf '[test] %s\n' "$*"
}

debug() {
  if [[ "${VERBOSE}" == "1" ]]; then
    printf '[debug] %s\n' "$*"
  fi
}

load_env_file() {
  ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
  if [[ ! -f "${ENV_FILE}" ]]; then
    printf 'ERROR: env file not found: %s\n' "${ENV_FILE}" >&2
    printf 'Tip: copy .env.example to .env and fill your postgres values.\n' >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  debug "Loaded env file: ${ENV_FILE}"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'ERROR: missing required env var %s\n' "${name}" >&2
    exit 1
  fi
}

require_common_env() {
  require_env "BASE_DB"
  require_env "PR_NUMBER"
  require_env "PGHOST"
  require_env "PGPORT"
  require_env "PGUSER"
  require_env "PGPASSWORD"
}

compute_names() {
  SOURCE_DB="${SOURCE_DB:-${BASE_DB}}"
  PREVIEW_DB="${PREVIEW_DB:-${BASE_DB}_pr_${PR_NUMBER}}"
  debug "Computed SOURCE_DB=${SOURCE_DB} PREVIEW_DB=${PREVIEW_DB}"
  debug "Connection target PGHOST=${PGHOST} PGPORT=${PGPORT} PGDATABASE=${PGDATABASE:-postgres} PGUSER=${PGUSER}"
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

start_source_connections() {
  local count="$1"
  local sleep_seconds="$2"

  if [[ "${count}" -le 0 ]]; then
    debug "Skipping source connection simulation (count=${count})"
    return 0
  fi

  info "Opening ${count} background connection(s) to source DB ${SOURCE_DB}"
  local i
  for ((i = 1; i <= count; i++)); do
    PGPASSWORD="${PGPASSWORD}" psql \
      -v ON_ERROR_STOP=1 \
      -X \
      -h "${PGHOST}" \
      -p "${PGPORT}" \
      -U "${PGUSER}" \
      -d "${SOURCE_DB}" \
      -Atqc "SELECT pg_sleep(${sleep_seconds});" >/dev/null 2>&1 &
    SOURCE_CONN_PIDS+=("$!")
  done

  sleep 1

  local alive=0
  local pid
  for pid in "${SOURCE_CONN_PIDS[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      alive=$((alive + 1))
    fi
  done

  if [[ "${alive}" -lt "${count}" ]]; then
    printf 'FAIL: expected %s active source connections, got %s\n' "${count}" "${alive}" >&2
    stop_source_connections
    exit 1
  fi

  debug "Active source connection pids: ${SOURCE_CONN_PIDS[*]}"
}

stop_source_connections() {
  local pid
  for pid in "${SOURCE_CONN_PIDS[@]}"; do
    kill "${pid}" >/dev/null 2>&1 || true
  done

  for pid in "${SOURCE_CONN_PIDS[@]}"; do
    wait "${pid}" >/dev/null 2>&1 || true
  done

  SOURCE_CONN_PIDS=()
}

assert_db_exists() {
  local db_name="$1"
  local expected="$2"
  local got
  got="$(psql_admin -Atqc "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = '${db_name}');")"
  if [[ "${got}" != "${expected}" ]]; then
    printf 'FAIL: expected DB %s exists=%s but got=%s\n' "${db_name}" "${expected}" "${got}" >&2
    exit 1
  fi
  debug "assert_db_exists OK: ${db_name} exists=${expected}"
}
