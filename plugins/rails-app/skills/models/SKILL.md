---
name: models
description: ActiveRecord models, migrations and schema — tables, columns, indexes, associations, validations, scopes — with PostgreSQL production safety. Use when adding or changing a table or a model, or when reviewing a migration before it ships.
argument-hint: "model, migration or schema task; or a migration file to review"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# Models: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`: **Tenant**, **Migrations**, **Verify**. A
missing label means "none". Write the model spec first (/flow:tdd). Query speed is /rails-app:database.

## Migrations

- Generate them: `bin/rails g migration AddFooToBars foo:string`. Never type a filename with a round
  time (`…0000`, `…1500`, `…3000`, `…4500`): two branches cut the same day land on one version, and
  once one is applied `db:migrate` silently skips the other. Writing the file yourself: version from
  `date -u +%Y%m%d%H%M%S`. Before merge, confirm main has no file with that version:
  `git ls-tree --name-only origin/main db/migrate/ | grep <version>`.
- Run up, down, up locally. The `db/schema.rb` diff holds only what you meant.
- Workflow → Migrations names the safety gem and the version check. Fix what the gem flags; a
  `safety_assured` needs a comment saying why the operation is safe on this table's size.

## Production safety (PostgreSQL)

| Change | Unsafe | Safe |
|---|---|---|
| Index on an existing table | plain `add_index` | `disable_ddl_transaction!` + `algorithm: :concurrently`. Without the first, PG refuses: `CREATE INDEX CONCURRENTLY cannot run inside a transaction block` |
| Unique index | build and hope | check for duplicates first; a failed concurrent build leaves an `INVALID` index, drop it before retrying |
| Reference | `add_reference …, foreign_key: true` | `add_reference …, index: { algorithm: :concurrently }`; `add_foreign_key …, validate: false`; `validate_foreign_key` in a follow-up migration |
| NOT NULL on an existing column | `null: false` or `change_column_null` on a large table (ACCESS EXCLUSIVE + full scan) | add nullable → backfill in batches (a task or job, not the migration) → `add_check_constraint "col IS NOT NULL", validate: false` → `validate_check_constraint` → `change_column_null` (instant once a validated CHECK covers it) |
| `change_column_null … validate: false` | does not exist | only `add_check_constraint` and `add_foreign_key` take `validate:` |
| Volatile default (`now()`, `gen_random_uuid()`) on a big table | rewrites the table | constant default (metadata-only on PG 11+), or backfill |
| `change_column_default` | expecting existing rows to change | it only affects future inserts; backfill separately |
| Drop a column | `remove_column` while code still reads it | deploy `self.ignored_columns += ["col"]` first, then drop; say so in the migration |
| Rename a column | `rename_column` (running instances break mid-deploy) | add new → backfill → switch reads and writes → drop old, across deploys |
| Change a type | `change_column` (table rewrite) | new column + backfill + swap |
| Data change | `update_all` over a large table inside a migration | batched task or job; a human-run one goes in the PR per Workflow → PR contract |
| Reversibility | `remove_column :t, :c` with no type | reversible `change`, or explicit `up`/`down` |

**Block the merge:** a non-concurrent index on a table you can show holds more than ~10k rows,
`null: false` on an existing column with no backfill in the PR, a drop with no earlier ignore deploy,
interpolated SQL.

## Models

- Tenant-owned tables (Workflow → Tenant) carry the tenant FK with a foreign key and an index;
  composite indexes lead with it. The model `belongs_to` the tenant or reaches it through a parent
  that does.
- Index every foreign key. Back every uniqueness validation with a unique index (the validation alone
  races).
- Money: `decimal` with explicit `precision` and `scale`, never `float`; a currency column beside an
  amount on a shared table. Match the precision already in `db/schema.rb`.
- Every `has_many`/`has_one` states `dependent:`. Destroying a large child set belongs in a job.
- Callbacks change only the record's own state. Mail, jobs and other aggregates go in a service
  (/rails-app:services).
- Scopes return relations: no `.to_a`, `.first` or `.pluck` inside one.
- Enumerated strings: a constant list + `inclusion` validation, and a check constraint when the column
  is written outside the model.

## Done when

- The spec covers validations, associations, scopes and every branch of new methods.
- The migration ran up, down, up; the schema diff is exactly the change.
- Workflow → Verify passes.
