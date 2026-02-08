#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/integration_helpers.sh
source "${ROOT_DIR}/tests/lib/integration_helpers.sh"

main() {
  load_env_file
  require_common_env
  compute_names

  printf 'Running ensure for preview DB %s (source=%s)\n' "${PREVIEW_DB}" "${SOURCE_DB}"
  "${SCRIPT_PATH}" ensure

  assert_db_exists "${PREVIEW_DB}" "t"
  printf 'PASS: preview DB created (%s)\n' "${PREVIEW_DB}"
}

main "$@"
