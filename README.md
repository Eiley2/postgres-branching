# Postgres Branching

![CI](https://github.com/Eiley2/postgres-branching/actions/workflows/ci.yml/badge.svg)
![Compatibility](https://github.com/Eiley2/postgres-branching/actions/workflows/compatibility.yml/badge.svg?branch=main&event=push)
![MIT License](https://img.shields.io/badge/license-MIT-green.svg)

GitHub Action toolkit to create, reset, and delete preview databases in the **same PostgreSQL instance**, similar to branching workflows.

## Actions

- `Eiley2/postgres-branching@v1` (single action with `command`)
- `Eiley2/postgres-branching/create@v1`
- `Eiley2/postgres-branching/reset@v1`
- `Eiley2/postgres-branching/delete@v1`

## Core behavior

- `create`: creates `branch_name` from `parent_branch`; if it already exists, it is a no-op.
- `reset`: recreates `branch_name` from `parent_branch`.
- `delete`: drops `branch_name` if present.
- Operations are serialized per `branch_name` with an advisory lock held for the full command lifecycle.
- If another operation already holds the lock for the same `branch_name`, the command waits up to `LOCK_WAIT_TIMEOUT_SEC` (default `300`) and then fails.

## Compatibility

- Verified in CI with PostgreSQL `13` to `18` (`compatibility.yml`).
- For clone operations (`create`/`reset`), `clone_strategy=auto` uses Docker `postgres:<server_major>` when local `pg_dump` major differs from server major.
- Docker clone mode propagates common `PG*` connection/SSL env vars (including `PGSSLMODE`, cert/key paths).
- If `clone_strategy=auto` or `clone_strategy=docker` requires Docker and Docker is unavailable, the command fails with an explicit error.

## Inputs

Common inputs:

- `branch_name` (required)
- `pg_host`, `pg_port`, `pg_user`, `pg_password` (required)
- `pg_database` (optional, default `postgres`)

Extra inputs for `create` and `reset`:

- `parent_branch` (required)
- `app_db_user` (optional, grants DB + schema/table/sequence privileges on the preview DB)
- `clone_strategy` (optional, default `auto`): `auto` picks local vs Docker by version compatibility, `local` forces local `pg_dump`/`pg_restore`, `docker` forces Docker client cloning.

## `with` field reference

Use this as a quick guide for what each `with` field does in workflow YAML.

- `command`: Operation to run in `Eiley2/postgres-branching@v1` (`create`, `reset`, `delete`).
- `branch_name`: Name of the preview database to create/reset/delete (for all actions).
- `parent_branch`: Source database used to clone data from (required for `create` and `reset`).
- `pg_host`: PostgreSQL host address (required for all actions).
- `pg_port`: PostgreSQL port (required for all actions).
- `pg_user`: PostgreSQL admin user used by the action (required for all actions).
- `pg_password`: Password for `pg_user` (required for all actions).
- `pg_database`: Administrative database where control statements run (optional, default `postgres`).
- `app_db_user`: Optional app role to grant access on the preview DB after `create`/`reset`.
- `clone_strategy`: Clone method for `create`/`reset` (`auto`, `local`, `docker`).

## Usage

### Single action + command

```yaml
- name: Create preview database
  uses: Eiley2/postgres-branching@v1
  with:
    command: create
    branch_name: app_pr_123
    parent_branch: app_main
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}
    pg_database: postgres
    clone_strategy: auto
```

### Sub-action: create

```yaml
- name: Create preview database
  uses: Eiley2/postgres-branching/create@v1
  with:
    branch_name: app_pr_123
    parent_branch: app_main
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}
    pg_database: postgres
    clone_strategy: auto
```

### Sub-action: reset

```yaml
- name: Reset preview database
  uses: Eiley2/postgres-branching/reset@v1
  with:
    branch_name: app_pr_123
    parent_branch: app_main
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}
    clone_strategy: auto
```

### Sub-action: delete

```yaml
- name: Delete preview database
  uses: Eiley2/postgres-branching/delete@v1
  with:
    branch_name: app_pr_123
    pg_host: ${{ secrets.PGHOST }}
    pg_port: ${{ secrets.PGPORT }}
    pg_user: ${{ secrets.PGUSER }}
    pg_password: ${{ secrets.PGPASSWORD }}
```

## Local testing

```bash
chmod +x tests/*.sh
./tests/test_create_action.sh
./tests/test_reset_action.sh
./tests/test_delete_action.sh

# Requires running PostgreSQL
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=postgres ./tests/test_create_action_integration.sh
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=postgres ./tests/test_reset_action_integration.sh
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=postgres ./tests/test_delete_action_integration.sh
```

## License

MIT
