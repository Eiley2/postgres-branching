#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/preview-branch.sh"

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

cleanup() {
  set +e
  psql_admin -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('${PARENT_BRANCH}','${PREVIEW_DB}') AND pid <> pg_backend_pid();" >/dev/null 2>&1
  psql_admin -c "DROP DATABASE IF EXISTS \"${PREVIEW_DB}\";" >/dev/null 2>&1
  psql_admin -c "DROP DATABASE IF EXISTS \"${PARENT_BRANCH}\";" >/dev/null 2>&1
}

main() {
  require_env PGHOST
  require_env PGPORT
  require_env PGUSER
  require_env PGPASSWORD

  PARENT_BRANCH="delete_parent_ci"
  BRANCH_NAME="delete_preview_ci"
  PREVIEW_DB="${BRANCH_NAME}"

  trap cleanup EXIT
  cleanup

  psql_admin -c "CREATE DATABASE \"${PARENT_BRANCH}\";"
  PGPASSWORD="${PGPASSWORD}" psql \
    -v ON_ERROR_STOP=1 \
    -X \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${PGUSER}" \
    -d "${PARENT_BRANCH}" \
    -c "
      CREATE TABLE keep_users (id integer primary key, name text not null);
      CREATE TABLE keep_orders (id integer primary key, user_id integer not null references keep_users(id), amount integer not null);
      INSERT INTO keep_users (id, name) VALUES (1, 'alice'), (2, 'bob');
      INSERT INTO keep_orders (id, user_id, amount) VALUES (1, 1, 15), (2, 2, 25);
    "

  psql_admin -c "CREATE DATABASE \"${PREVIEW_DB}\";"
  PGPASSWORD="${PGPASSWORD}" psql \
    -v ON_ERROR_STOP=1 \
    -X \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${PGUSER}" \
    -d "${PREVIEW_DB}" \
    -c "
      CREATE TABLE keep_users (id integer primary key, name text not null);
      CREATE TABLE keep_orders (id integer primary key, user_id integer not null references keep_users(id), amount integer not null);
      INSERT INTO keep_users (id, name) VALUES (1, 'alice-preview'), (2, 'bob-preview');
      INSERT INTO keep_orders (id, user_id, amount) VALUES (1, 1, 99), (2, 2, 199);
    "

  src_users_before="$(table_fingerprint "${PARENT_BRANCH}" "keep_users")"
  src_orders_before="$(table_fingerprint "${PARENT_BRANCH}" "keep_orders")"

  BRANCH_NAME="${BRANCH_NAME}" \
  PGHOST="${PGHOST}" \
  PGPORT="${PGPORT}" \
  PGUSER="${PGUSER}" \
  PGPASSWORD="${PGPASSWORD}" \
  PGDATABASE="${PGDATABASE:-postgres}" \
  "${SCRIPT_PATH}" delete

  exists="$(psql_admin -Atqc "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = '${PREVIEW_DB}');")"
  if [[ "${exists}" != "f" ]]; then
    printf 'FAIL: expected preview db %s to be deleted\n' "${PREVIEW_DB}" >&2
    exit 1
  fi

  src_exists="$(psql_admin -Atqc "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = '${PARENT_BRANCH}');")"
  if [[ "${src_exists}" != "t" ]]; then
    printf 'FAIL: parent branch db %s should remain after delete\n' "${PARENT_BRANCH}" >&2
    exit 1
  fi

  src_users_after="$(table_fingerprint "${PARENT_BRANCH}" "keep_users")"
  src_orders_after="$(table_fingerprint "${PARENT_BRANCH}" "keep_orders")"
  if [[ "${src_users_before}" != "${src_users_after}" || "${src_orders_before}" != "${src_orders_after}" ]]; then
    printf 'FAIL: parent branch db data changed after delete action\n' >&2
    exit 1
  fi

  echo "PASS: delete action integration test"
}

main "$@"
