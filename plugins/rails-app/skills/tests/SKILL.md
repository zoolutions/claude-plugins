---
name: tests
description: RSpec specs and FactoryBot factories — choosing the spec type, system specs for browser behaviour, explicit tenant factory chains and cross-tenant checks. Use when writing or fixing specs or factories, or raising coverage.
argument-hint: "spec file, model, feature or behaviour to test"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# Tests: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`: **Specs** (fast loop, full suite,
sign-in and host helpers, the wait helper, whether the agent may run specs), **Tenant** (factory
chain). Default stack: RSpec, FactoryBot, Capybara with Playwright. RED → GREEN → REFACTOR is
/flow:tdd; a flaky spec is /flow:debug-flaky.

## Pick the type

| Behaviour | Spec |
|---|---|
| Anything that runs in the browser: JavaScript, Turbo, phlex-reactive, multi-step journeys | **System spec** — a request spec does not prove it |
| A feature's create → view → edit → delete | one system example with named steps, each ending on server truth (reload, flash, path, record), never on a click |
| Authorization edges per role, cross-tenant access, a regression, a JSON endpoint | request spec |
| Policy rules | policy spec |
| Validations, scopes, model methods | model spec |
| Services, jobs, mailers, components | their own spec type |

Never a request spec that repeats a CRUD happy path the system spec already walks.

## Factories

- Build the tenant chain explicitly (Workflow → Tenant): `let(:tenant)`, then each parent passed in.
  A factory that silently cascade-creates parents makes slow specs and a second tenant you didn't
  ask for.
- Never shadow an outer `let(:tenant)` in a nested context; use `let(:other_tenant)`.
- Every feature that reads tenant data gets one cross-tenant example: a record of `other_tenant` is
  invisible or answers 404.
- Traits over fixtures; `build_stubbed` when nothing needs persisting; `let` (lazy) over `let!`
  unless the record must exist before the action.

## Writing them

- Sign in and set the host with the helpers Workflow → Specs names, not by filling the login form in
  every spec.
- Capybara's waiting matchers (`have_content`, `have_current_path`), never `sleep`. After each
  reactive interaction, the wait helper Workflow → Specs names.
- External HTTP stubbed (WebMock/VCR); time frozen with `travel_to`; no real IDs or dates hardcoded.
- Assert behaviour (what the user or the database sees), not which private method ran.

## A failing spec

Fix the code or fix the spec. Never a guard that skips the path, `find` → `find_by` to dodge an
exception, `rescue nil`, `skip`/`pending` without a linked issue, or a loosened matcher that would pass
on the bug.

## Coverage

80% minimum; 100% for money, authorization, authentication and security-critical code.

## Running

Fast loop and full suite per Workflow → Specs. When Workflow → Specs says the agent cannot run specs
in this environment, print the exact command (`bundle exec rspec path/to/spec.rb:42`) and wait for the
pasted result instead of guessing it passed.

Done when the specs are green, each new branch is covered, and Workflow → Verify passes.
