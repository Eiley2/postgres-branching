# Release Notes - v1.0.4

## Highlights

- Added robust stale-lock self-healing to avoid manual unlocks after interrupted runners.
- Reduced default advisory lock wait timeout from 300s to 180s.
- Added integration coverage for double-`create` runs to catch lock-leak/deadlock regressions.

## What Changed

- Lock acquisition hardening:
  - Added lock-holder app name: `postgres-branching-lock-holder`.
  - Added lock-holder keepalive tuning for faster dead-session detection:
    - `LOCK_TCP_KEEPALIVES_IDLE_SEC` (default `30`)
    - `LOCK_TCP_KEEPALIVES_INTERVAL_SEC` (default `10`)
    - `LOCK_TCP_KEEPALIVES_COUNT` (default `3`)
  - Added stale-lock cleanup on timeout with one retry:
    - `LOCK_STALE_AFTER_SEC` (default `1800`)
- Reduced default lock wait timeout:
  - `LOCK_WAIT_TIMEOUT_SEC` default changed from `300` to `180`.
- Expanded docs:
  - Added lock behavior details and lock tuning environment variables.
- New integration safety test:
  - `create` run twice in sequence on the same branch.
  - Verifies second run is no-op and no lingering lock-holder query remains.

## Validation

- Unit tests:
  - `tests/test_create_action.sh`
  - `tests/test_delete_action.sh`
  - `tests/test_reset_action.sh`
- Integration script syntax:
  - `tests/test_create_action_integration.sh`

## Compatibility

- No breaking input/output changes.
- Existing workflows remain compatible.
