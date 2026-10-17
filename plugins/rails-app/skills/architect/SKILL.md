---
name: architect
description: Coordinate a feature that spans several Rails layers — map the layers, order the work, hand each layer to its specialist, and check the cross-cutting rules before the PR. Use for multi-layer features or architectural decisions; single-layer work goes straight to that layer's skill.
argument-hint: "feature, issue number or architectural question"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent, Skill
model: opus
---

# Architect: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`, all of it: the specialists act on its
labels. A missing label means "none"; only a label that is wrong (the tree contradicts it) is the
first thing to fix (or ask about).

Unknown scope, a schema or public API choice, or more than a day of work: `/flow:plan` first and work
from the plan. Executing an issue end to end is `/flow:lfg`; this skill is the layer map it follows.

## Order

| # | Layer | Skill |
|---|---|---|
| 1 | Schema, migrations, models | /rails-app:models |
| 2 | Business logic, external APIs | /rails-app:services |
| 3 | Entry points: controllers, routes, API | /rails-app:controllers |
| 4 | Async and recurring work | /rails-app:jobs |
| 5 | Pages and components | /rails-app:views |
| 6 | Interactivity | /rails-app:stimulus |
| 7 | Copy, mail, notifications | /rails-app:i18n, /rails-app:mailers |
| 8 | Query performance, security pass | /rails-app:database, /rails-app:security |

Specs are written first in every layer (/flow:tdd, /rails-app:tests); the system spec for the whole
flow is written before layer 5.

## Delegate or do

- Delegate a layer when it spans several files and its inputs are settled: an Agent with
  `model: sonnet`, the skill to load, the files, the contract from the previous layer (names, columns,
  method signatures) and the acceptance criteria. Dependent layers run in order; independent ones
  (mailer copy and a job, say) in parallel.
- Do it yourself when it is one file, or when the change is cross-cutting and splitting it would lose
  the thread.

## Decisions

| Question | Default |
|---|---|
| Model method or service? | the record's own state → model; several records, external calls or a workflow → service |
| Inline or job? | external call, mail, file processing or more than ~500 ms → job |
| Component or inline markup? | used twice, or streamed/morphed/broadcast → component |
| How does the page update? | Follow Workflow → Interactivity: when it names phlex-reactive, client ops for client-only changes, a reactive action answering with `reply.morph`/`reply.replace`/`reply.also` for server changes, `broadcast_to` only for other viewers, never a new Turbo Stream by default; otherwise the app's existing client stack |
| New table or column? | a column unless it has its own lifecycle or cardinality |
| A gem? | only after reading what the app already has; a dependency is an advisor-level decision |

## Cross-cutting checklist (every feature)

- [ ] Every query starts from the tenant root (Workflow → Tenant), in jobs and services too.
- [ ] Every entry point authorizes: controller action, reactive action, API, webhook, job that acts
      for a user.
- [ ] Migrations follow /rails-app:models' safety table; a backfill has an owner.
- [ ] No N+1 on the new pages (/rails-app:database `diff`).
- [ ] Every user-visible string is a fully qualified key.
- [ ] Slow work is in jobs that are idempotent.
- [ ] A system spec walks the feature; request specs cover role and cross-tenant edges.
- [ ] Operator actions, screenshots and labels per Workflow → PR contract.

## Before the PR

Run the `flow:fable-validator` agent on `git diff origin/main...HEAD` with the issue and its acceptance
criteria. BLOCK: do not open or merge; report the blockers. PASS: open the PR and hand it to
`/flow:finish-prs <PR>`.

Report: the layer plan, what each specialist delivered, the decisions taken and why, open risks.
