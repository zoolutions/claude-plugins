---
name: services
description: Service objects for business logic, multi-step workflows and external API clients. Use when logic outgrows a controller action or model method, when several records change together, or when calling a third-party API.
argument-hint: "workflow, business rule or integration task"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# Services: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`: **Services** (base class, result shape),
**Tenant**, **Authorization**, **Jobs**. Read two existing services in the same domain before writing
a third.

## Shape

- Inherit the base Workflow → Services names (default: `ApplicationService` with
  `def self.call(...) = new(...).call`). One public `call`; inputs as keyword args.
- Return what Workflow → Services says the app returns (a Success/Failure result where the caller
  branches, an exception for a broken contract). Never add a second result type beside it.
- Location by domain: `app/services/<domain>/<verb>_<noun>.rb`, not one folder of everything.
- Methods under ~30 lines; a service that needs a diagram is two services.

## Tenant and authorization

- Receive tenant-scoped records or the tenant itself; never query globally inside a service. Read
  `Current.*` at the edge (controller, job, reactive action) and pass it in.
- A service called from more than one entry point (controller, job, API, reactive action) authorizes
  at the entry point; one that is itself an entry point (an API or tool handler) authorizes inside, per
  Workflow → Authorization.

## Writes

- Several records that must change together: one `transaction`. Mail and jobs are enqueued after the
  commit (outside the block or in `after_commit`), so a job never reads rows that rolled back.
- Race-prone read-modify-write: `with_lock`, or a unique index plus handling
  `ActiveRecord::RecordNotUnique`. Never "check then insert" alone.
- Rescue the specific exception and return a failure or re-raise. Never `rescue StandardError`,
  `rescue nil`, or a bare `rescue => e` that only logs.

## External API clients

- One client class per provider; HTTP lives there, mapping to the domain happens in the service.
- Set open and read timeouts explicitly. Map responses to typed errors (authentication, rate limit,
  client, server) instead of returning `nil`.
- Retry only idempotent calls on transient errors (timeouts, 429, 5xx), with backoff and a cap;
  prefer the job's `retry_on` to sleeping in a request.
- Credentials from Rails credentials or the app's config object, never a literal; log requests
  without auth headers, tokens or personal data.
- Specs stub HTTP (WebMock or VCR); a spec never reaches the network.
- Incoming webhooks: signature first (/rails-app:security), then enqueue a job with the payload and
  answer `head :ok` fast.

## Never

| Wrong | Right |
|---|---|
| Several public methods | one `call` |
| `Thing.find(id)` inside the service | a record handed in, or `tenant.things.find(id)` |
| `deliver_later`/`perform_later` inside the transaction | after commit |
| `rescue StandardError` / `rescue nil` | the specific error, then failure or re-raise |
| `true`/`false` where the caller needs a reason | the app's result type |

## Done when

- A service spec covers success, each failure branch and the transaction rollback.
- Workflow → Verify passes.
