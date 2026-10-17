---
name: database
description: Query performance — N+1 queries, missing indexes, EXPLAIN plans, batching and bulk writes. Use when a page or job is slow, or with 'diff' to audit the branch for N+1 patterns before review.
argument-hint: "slow endpoint, query or job; or 'diff' to audit the branch"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# Database: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`: **Tenant**, **N+1**, **APM**. Schema and
migration changes go through /rails-app:models.

## Measure before changing anything

- Reproduce with production-shaped data (Workflow → APM names a local production copy when there is
  one). `relation.explain(:analyze)` or `EXPLAIN (ANALYZE, BUFFERS)` in psql. Keep the plan, query
  count and ms from before; the PR shows before and after.
- In the log, many identical `SELECT … WHERE id = $1` (or `[CACHE]` hits) from one call site means a
  missing preload.
- The spec-time guard in Workflow → N+1 raises on repeated queries: fix the query, never silence the
  guard around the spec.

## N+1 audit (`diff`)

`git diff origin/main...HEAD -- 'app/**/*.rb'`; read the models it touches for association names; flag:

| Pattern | Fix |
|---|---|
| `each`/`map`/`select` over a relation touching an association | `includes`/`preload` on the source query |
| A view or component iterating a collection | find the controller (or caller) that built it: the finding and the fix go on that line, not the view's |
| `find`/`find_by` inside a loop | one `where(id: ids).index_by(&:id)` |
| `.count`/`.exists?`/`.any?` per record | counter cache, or preload + `.size` |
| A method or service called per record that queries | read it: N+1 in disguise; batch its input |
| `.each` over an unbounded relation | `find_each`/`in_batches` (memory, and one job enqueued per row) |
| The same parent looked up per row | preload it once or memoize per request |

Not findings: iteration over constants or in-memory arrays, primitive columns of the iterated table,
spec setup, associations already preloaded.

Report: `Definite` and `Likely (verify)` lists, each `file:line — problem — one-line fix`, then a
verdict. Clean: `Clean — no N+1 patterns in <scope>.` Nothing else.

## Rules

- Every query on tenant data starts from the tenant root (Workflow → Tenant), in jobs and services
  too. An unscoped `Model.find(params[:id])` is a data leak before it is a performance bug.
- Composite index order: tenant FK, then equality columns, then the range or sort column. A partial
  index for a hot filtered subset (`WHERE deleted_at IS NULL`).
- `exists?` over `count > 0`; `pluck` when you need values, not records; `size` on a loaded
  association, `count` only when you want the SQL.
- Bulk writes: `insert_all`/`upsert_all(unique_by:)` skip validations and callbacks (say so in the
  PR); `update_all` for set-based changes; `in_batches` on large tables.
- Locks: `with_lock`/`lock` only around the read-modify-write, never across an HTTP call.
- Cache only after the query is right; key on `cache_key_with_version`.

## Done when

- Before/after numbers (query count, ms or plan) are in the PR body.
- A spec covers the fixed path with the N+1 guard on, or pins the query count.
- Workflow → Verify passes.
