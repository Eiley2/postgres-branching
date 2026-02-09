# Release Notes - v1.0.3

## Highlights

- `create` is now retry-safe in CI/CD when a previous run left the operation lock active.
- Action logs were expanded to make GitHub Actions output much easier to follow.
- Docker/client-version fallback now explains exactly why Docker is being used.

## What Changed

- Added `create` fallback behavior:
  - If lock wait times out and preview DB already exists, `create` exits successfully as a no-op.
- Added more operational logs across the workflow:
  - command start context (`command`, `branch`, lock/clone settings)
  - lock behavior (disabled, waiting, acquired, timeout fallback)
  - create/reset/delete intent
  - clone strategy decisions and completion (local vs docker)
  - grant step skipped when `APP_DB_USER` is not provided
- Improved Docker messaging:
  - explicit mismatch reason (local client major vs server major)
  - clearer guidance to install Docker when required

## Tests

- Added/updated create-action tests to cover:
  - timeout + existing preview DB no-op path
  - docker-switch log visibility on version mismatch
- Existing create/delete/reset test suites continue passing.

## Compatibility

- No breaking input/output changes.
- Existing workflows remain compatible.
