# Postgres Branching

![CI](https://github.com/Eiley2/postgres-branching/actions/workflows/ci.yml/badge.svg)
![Compatibility](https://github.com/Eiley2/postgres-branching/actions/workflows/compatibility.yml/badge.svg)
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

## Compatibility

- Verified in CI with PostgreSQL `13` to `18` (`compatibility.yml`).
- For clone operations (`create`/`reset`), if local `pg_dump` major differs from server major, the script uses Docker `postgres:<server_major>` client automatically.

## Inputs

Common inputs:

- `branch_name` (required)
- `pg_host`, `pg_port`, `pg_user`, `pg_password` (required)
- `pg_database` (optional, default `postgres`)

Extra inputs for `create` and `reset`:

- `parent_branch` (required)
- `app_db_user` (optional)

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
