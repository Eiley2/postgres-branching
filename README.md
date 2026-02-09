# Postgres Branching

![CI](https://github.com/Eiley2/postgres-branching/actions/workflows/ci.yml/badge.svg)
![Compatibility](https://github.com/Eiley2/postgres-branching/actions/workflows/compatibility.yml/badge.svg?branch=main&event=push)
![MIT License](https://img.shields.io/badge/license-MIT-green.svg)

GitHub Action toolkit to **create**, **reset**, and **delete** preview databases inside the same PostgreSQL instance -- similar to git branching but for databases.

---

## Quick start

```yaml
- uses: Eiley2/postgres-branching@v1
  with:
    command: create
    branch_name: app_pr_${{ github.event.pull_request.number }}
    parent_branch: app_main
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}
```

This creates a preview database named `app_pr_<number>` cloned from `app_main`. If it already exists, the step is a no-op.

---

## How it works

| Command    | Behavior |
|------------|----------|
| **create** | Creates `branch_name` by cloning `parent_branch`. If the preview DB already exists, it is a **no-op**. |
| **reset**  | Drops and recreates `branch_name` from `parent_branch` (a full re-clone). |
| **delete** | Drops `branch_name` if it exists. Does nothing otherwise. |

All operations:

- Are **serialized per `branch_name`** using a PostgreSQL advisory lock held for the full command lifecycle.
- If another operation already holds the lock for the same `branch_name`, the command waits up to `LOCK_WAIT_TIMEOUT_SEC` (default `300` seconds) and then fails.
- On clone failure (`create`/`reset`), the incomplete preview database is automatically cleaned up.
- When `app_db_user` is set (`create`/`reset`), the action grants `CONNECT`, schema `USAGE`, and full privileges on all tables and sequences -- including `ALTER DEFAULT PRIVILEGES` so future objects are also accessible.

---

## Actions

You can use a single unified action, or call each command as a dedicated sub-action.

| Action | Description |
|--------|-------------|
| `Eiley2/postgres-branching@v1` | Unified action -- pass `command: create\|reset\|delete` |
| `Eiley2/postgres-branching/create@v1` | Creates a preview database from a parent |
| `Eiley2/postgres-branching/reset@v1` | Drops and re-creates a preview database from a parent |
| `Eiley2/postgres-branching/delete@v1` | Drops a preview database |

---

## Inputs

### Unified action (`Eiley2/postgres-branching@v1`)

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `command` | yes | -- | Operation to perform: `create`, `reset`, or `delete`. |
| `branch_name` | yes | -- | Name of the preview database to manage. |
| `parent_branch` | yes (`create`, `reset`) | `""` | Source database to clone data from. |
| `pg_host` | yes | -- | PostgreSQL host address. |
| `pg_port` | yes | -- | PostgreSQL port. |
| `pg_user` | yes | -- | PostgreSQL admin user. |
| `pg_password` | yes | -- | Password for `pg_user`. |
| `pg_database` | no | `postgres` | Administrative database where control statements run. |
| `app_db_user` | no | `""` | App role to grant access on the preview DB after `create`/`reset`. |
| `clone_strategy` | no | `auto` | Clone method: `auto`, `local`, or `docker`. Ignored by `delete`. |

### Sub-action: create (`Eiley2/postgres-branching/create@v1`)

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `branch_name` | yes | -- | Name of the preview database to create. |
| `parent_branch` | yes | -- | Source database to clone data from. |
| `pg_host` | yes | -- | PostgreSQL host address. |
| `pg_port` | yes | -- | PostgreSQL port. |
| `pg_user` | yes | -- | PostgreSQL admin user. |
| `pg_password` | yes | -- | Password for `pg_user`. |
| `pg_database` | no | `postgres` | Administrative database where control statements run. |
| `app_db_user` | no | `""` | App role to grant access on the preview DB. |
| `clone_strategy` | no | `auto` | Clone method: `auto`, `local`, or `docker`. |

### Sub-action: reset (`Eiley2/postgres-branching/reset@v1`)

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `branch_name` | yes | -- | Name of the preview database to reset. |
| `parent_branch` | yes | -- | Source database to restore from. |
| `pg_host` | yes | -- | PostgreSQL host address. |
| `pg_port` | yes | -- | PostgreSQL port. |
| `pg_user` | yes | -- | PostgreSQL admin user. |
| `pg_password` | yes | -- | Password for `pg_user`. |
| `pg_database` | no | `postgres` | Administrative database where control statements run. |
| `app_db_user` | no | `""` | App role to grant access on the preview DB. |
| `clone_strategy` | no | `auto` | Clone method: `auto`, `local`, or `docker`. |

### Sub-action: delete (`Eiley2/postgres-branching/delete@v1`)

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `branch_name` | yes | -- | Name of the preview database to delete. |
| `pg_host` | yes | -- | PostgreSQL host address. |
| `pg_port` | yes | -- | PostgreSQL port. |
| `pg_user` | yes | -- | PostgreSQL admin user. |
| `pg_password` | yes | -- | Password for `pg_user`. |
| `pg_database` | no | `postgres` | Administrative database where control statements run. |

---

## Outputs

All actions expose a single output:

| Output | Description |
|--------|-------------|
| `preview_db` | The resolved preview database name (equal to `branch_name`). |

Example:

```yaml
- name: Create preview database
  id: preview
  uses: Eiley2/postgres-branching/create@v1
  with:
    branch_name: app_pr_123
    parent_branch: app_main
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}

- name: Run migrations
  run: echo "Connecting to ${{ steps.preview.outputs.preview_db }}"
```

---

## Clone strategy

The `clone_strategy` input controls how `create` and `reset` copy data from the parent database.

| Value | Behavior |
|-------|----------|
| `auto` (default) | Uses local `pg_dump`/`pg_restore` when the runner's client major version matches the server. Falls back to Docker automatically on mismatch. |
| `local` | Always uses the runner's local `pg_dump`/`pg_restore`. Use this when you manage runner tooling yourself. |
| `docker` | Always runs `pg_dump`/`pg_restore` inside a `postgres:<server_major>` Docker container. Use this for consistent client behavior across runners. |

When Docker is required (`auto` fallback or explicit `docker`) and Docker is not available on the runner, the action fails with a clear error.

Docker clone mode automatically:

- Propagates common `PG*` connection and SSL environment variables (`PGSSLMODE`, `PGSSLROOTCERT`, `PGSSLCERT`, `PGSSLKEY`, etc.).
- Mounts SSL certificate and key files as read-only volumes.
- Rewrites `localhost`/`127.0.0.1` to `host.docker.internal` so the container can reach the host network.

---

## Usage examples

### Unified action

```yaml
# Create
- uses: Eiley2/postgres-branching@v1
  with:
    command: create
    branch_name: app_pr_123
    parent_branch: app_main
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}

# Reset
- uses: Eiley2/postgres-branching@v1
  with:
    command: reset
    branch_name: app_pr_123
    parent_branch: app_main
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}

# Delete
- uses: Eiley2/postgres-branching@v1
  with:
    command: delete
    branch_name: app_pr_123
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}
```

### Sub-actions

```yaml
# Create
- uses: Eiley2/postgres-branching/create@v1
  with:
    branch_name: app_pr_123
    parent_branch: app_main
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}
    clone_strategy: auto

# Reset
- uses: Eiley2/postgres-branching/reset@v1
  with:
    branch_name: app_pr_123
    parent_branch: app_main
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}
    clone_strategy: auto

# Delete
- uses: Eiley2/postgres-branching/delete@v1
  with:
    branch_name: app_pr_123
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}
```

### PR lifecycle (full example)

```yaml
name: Preview DB

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

jobs:
  preview:
    runs-on: ubuntu-latest
    steps:
      - name: Create or reset preview DB
        if: github.event.action != 'closed'
        uses: Eiley2/postgres-branching@v1
        with:
          command: ${{ github.event.action == 'opened' && 'create' || 'reset' }}
          branch_name: app_pr_${{ github.event.pull_request.number }}
          parent_branch: app_main
          app_db_user: my_app_role
          pg_host: ${{ secrets.PGHOST }}
          pg_port: ${{ secrets.PGPORT }}
          pg_user: ${{ secrets.PGUSER }}
          pg_password: ${{ secrets.PGPASSWORD }}

      - name: Delete preview DB on close
        if: github.event.action == 'closed'
        uses: Eiley2/postgres-branching@v1
        with:
          command: delete
          branch_name: app_pr_${{ github.event.pull_request.number }}
          pg_host: ${{ secrets.PGHOST }}
          pg_port: ${{ secrets.PGPORT }}
          pg_user: ${{ secrets.PGUSER }}
          pg_password: ${{ secrets.PGPASSWORD }}
```

---

## Compatibility

- Verified in CI against PostgreSQL **13**, **14**, **15**, **16**, **17**, and **18** (`compatibility.yml`).
- `branch_name` and `parent_branch` must contain only letters, numbers, and underscores (validated at runtime).
- `pg_user` needs permissions to create/drop databases, terminate backends, and acquire advisory locks.

---

## Local testing

Unit tests (mocked, no database required):

```bash
chmod +x tests/*.sh
./tests/test_create_action.sh
./tests/test_reset_action.sh
./tests/test_delete_action.sh
```

Integration tests (require a running PostgreSQL instance):

```bash
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=postgres

./tests/test_create_action_integration.sh
./tests/test_reset_action_integration.sh
./tests/test_delete_action_integration.sh
```

---

## License

MIT
