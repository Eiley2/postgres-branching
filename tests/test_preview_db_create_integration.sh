#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/integration_helpers.sh
source "${ROOT_DIR}/tests/lib/integration_helpers.sh"

main() {
  load_env_file
  require_common_env
  compute_names

  trap stop_source_connections EXIT
  start_source_connections "${SOURCE_CONN_COUNT}" "${SOURCE_CONN_SLEEP_SECONDS}"

  info "Running create for preview DB ${PREVIEW_DB} (source=${SOURCE_DB})"
  "${SCRIPT_PATH}" create

  assert_db_exists "${PREVIEW_DB}" "t"
  stop_source_connections
  trap - EXIT
  info "PASS preview DB created (${PREVIEW_DB})"
}

main "$@"
