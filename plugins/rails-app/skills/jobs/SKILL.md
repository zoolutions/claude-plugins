---
name: jobs
description: Background jobs and recurring tasks — idempotent, tenant-aware, with bounded retries. Use when moving slow work out of a request, processing a webhook, scheduling a recurring task, or removing or renaming a job class.
argument-hint: "job, schedule or async task"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# Jobs: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow` → **Jobs** names the backend (default:
pgbus through ActiveJob), the job directories and the recurring-schedule file. An app with two
systems (ActiveJob jobs and Sidekiq workers) follows the pattern of the directory it is changing.

## Writing a job

- Arguments are IDs and primitives, never records: plus the tenant ID when the record is tenant-owned.
  Reload through the tenant root (Workflow → Tenant) and check the tenant still exists and still has
  the feature enabled before working.
- Idempotent: safe to run twice. Guard on persisted state, and re-check inside a lock:
  ```ruby
  def perform(tenant_id, thing_id)
    tenant = Tenant.find_by(id: tenant_id)            # Workflow → Tenant names the root
    return unless tenant&.feature_enabled?(:things)    # gone or switched off: nothing to do
    thing = tenant.things.find(thing_id)
    return if thing.processed?
    thing.with_lock do
      return if thing.processed?
      Things::Process.call(thing:)
    end
  end
  ```
- Retries: `retry_on <transient error>, wait: :polynomially_longer, attempts: N` with a cap;
  `discard_on ActiveRecord::RecordNotFound` when the record may legitimately vanish. Never unbounded
  retries; never `retry_on StandardError` around work that is not idempotent.
- Business logic lives in a service (/rails-app:services); the job loads, guards and calls it.
- Fan-out: a parent iterates `find_each`/`in_batches` and enqueues one child per batch. Never one job
  that walks every tenant in one transaction.
- Queue: pick the existing queue whose latency matches; a new queue also needs the worker config.

## Removing or renaming a job class

A payload already enqueued, a retry in flight, a dead-letter row or a schedule entry can still name
the old class, and fails with `ActiveJob::UnknownJobClassError`/`NameError` after the deploy.

1. Remove the schedule entry in the same PR (grep the schedule file for `class: <Name>`).
2. Keep the old class (or an alias constant delegating to the new one) until the queue and dead
   letters hold no payload naming it; then delete it in a later PR.

## Recurring and one-off work

- Recurring: an entry in the schedule file Workflow → Jobs names; the job itself stays idempotent
  (overlapping runs happen).
- An after-deploy backfill: an idempotent job or task, listed per Workflow → PR contract when a human
  runs it.

## Spec

- Job spec with `perform_now`: the happy path, the guard (run it twice, the effect happens once), the
  missing record, the tenant without the feature.
- Callers: `expect { … }.to have_enqueued_job(ThingJob).with(thing.id)`.

Done when the specs are green and Workflow → Verify passes.
