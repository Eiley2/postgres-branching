#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/preview-db.sh"

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

assert_db_exists() {
  local db_name="$1"
  local expected="$2"
  local got
  got="$(psql_admin -Atqc "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = '${db_name}');")"
  if [[ "${got}" != "${expected}" ]]; then
    printf 'FAIL: expected DB %s exists=%s but got=%s\n' "${db_name}" "${expected}" "${got}" >&2
    exit 1
  fi
}
