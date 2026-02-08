#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/integration_helpers.sh
source "${ROOT_DIR}/tests/lib/integration_helpers.sh"

main() {
  load_env_file
  require_common_env
  compute_names

  info "Running drop for preview DB ${PREVIEW_DB}"
  "${SCRIPT_PATH}" drop

  assert_db_exists "${PREVIEW_DB}" "f"
  info "PASS preview DB removed (${PREVIEW_DB})"
}

main "$@"
