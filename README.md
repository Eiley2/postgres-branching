# db-preview-branching

Reusable GitHub Action to create/drop PostgreSQL preview databases per pull request.

## What It Does

- `create` mode:
  - If preview DB does not exist: creates it and clones data from `SOURCE_DB` using `pg_dump | pg_restore`.
  - If preview DB already exists: no-op (success).
- `drop` mode:
  - Terminates active sessions on preview DB and drops it.

This avoids `CREATE DATABASE ... TEMPLATE` lock limitations when the source DB has active connections.

## Use From Other Repositories (Action)

```yaml
name: Preview DB

on:
  pull_request:
    types: [opened, reopened, synchronize, closed]

permissions:
  contents: read

jobs:
  preview-db:
    runs-on: ubuntu-latest
    steps:
      - name: Create/Drop preview DB
        uses: Eiley2/db-preview-branching@main
        with:
          mode: ${{ github.event.action == 'closed' && 'drop' || 'create' }}
          base_db: geopark
          pr_number: ${{ github.event.number }}
          source_db: geopark
          pg_host: ${{ secrets.PGHOST }}
          pg_port: "5432"
          pg_user: ${{ secrets.PGUSER }}
          pg_password: ${{ secrets.PGPASSWORD }}
          pg_database: postgres
```

## Use From Other Repositories (Reusable Workflow)

Call this reusable workflow:

`Eiley2/db-preview-branching/.github/workflows/preview-db-reusable.yml@main`

with:
- `event_action`
- `base_db`
- `pr_number`
- optional `source_db`, `app_db_user`, `pg_port`, `pg_database`, `action_repository`, `action_ref`
- secrets `pg_host`, `pg_user`, `pg_password`

For production, pass `action_ref` as a full commit SHA.

## Recommended Security Defaults

- Pin `uses:` to a full commit SHA in production repositories.
- Keep `permissions` minimal (`contents: read` by default).
- Prefer short-lived credentials (OIDC) when possible.
- Scope DB user privileges to only what is required for create/drop/restore operations.
