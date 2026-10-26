---
name: tdd
description: Implement a behaviour or fix a bug test-first — RED (a failing test, seen failing for the right reason), GREEN (the least code that passes), REFACTOR (still green), then the repository's checks. Use for any feature or bug fix, alone or as /flow:lfg's implementation step.
argument-hint: "<behaviour to implement, or the bug to reproduce>"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# TDD: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`: **Specs** gives the fast loop (one file),
the full suite and `changed` (the tests for the diff), **Verify** the checks a change must pass. A
missing label means "none". The test framework, file layout, fixtures and stubbing style are
whatever `AGENTS.md` and the nearest existing test show: copy the neighbouring test's shape; never
bring in a framework or helper the suite lacks.

**Pick the layer.** The cheapest test that proves what a caller depends on: a unit test for logic, a
request or integration test for an endpoint or a contract between parts, a browser or end-to-end
test for behaviour that lives in the browser or spans steps (when `AGENTS.md` prefers one kind,
follow it). A bug gets a test that reproduces it, where a user would see it, before anything is fixed.

## 1. RED

Write the test for one behaviour, named for the behaviour. Before running it, know what the right
failure looks like: a missing class or method raises; a wrong value prints an expected/actual diff;
a missing record comes back empty. No stub implementation first — a missing thing raising is RED.

Run the fast loop and quote the line that proves the failure. A failure for the wrong reason (a
typo, a fixture that does not load, a missing require, a syntax error) is not RED: fix the test and
run it again. A test that passes before the change tests nothing: tighten it, or say the behaviour
already exists.

## 2. GREEN

The least code that makes that test pass — not the sibling case, not the next feature, not a nearby
cleanup. Put it where the code already keeps this behaviour; a generated, vendored or upstream-owned
file changes only the way `AGENTS.md` allows. Run the fast loop: green because the failing assertion
now holds, never because one was deleted, loosened or skipped.

## 3. REFACTOR

Names, duplication, extraction — in the code and the test — with the fast loop green after each step.

## 4. Next case

One cycle per case: the happy path, the edges (empty, nil, zero, negative, the maximum, each
boundary), every error path, every branch the change adds.

## Every test, every cycle

- **Assert every observable effect.** Two records changed, a message and a status: assert both.
- **Behaviour, not implementation.** No private methods, call counts or regex internals.
- **Stub only at a boundary the code does not own** (network, clock, external process, third-party
  client), never inside the unit under test. Prefer real objects for internal code.
- **Restore what you write.** A global setting, a class-level accessor, an env var, a file, the
  clock: set in the test, restored after it, even when it fails.
- **Live calls pin exact versions**, so an upstream release cannot change what "pass" means.
- **Fixtures fork, never mutate.** A new shape gets its own fixture; one others rely on stays as is.

## Never

- Implementation before its test, or more than one behaviour per cycle.
- `retry`, `sleep`, `skip` without a stated reason, a loosened or deleted assertion, a commented-out
  test. A test that fails only sometimes has a cause: `/flow:debug-flaky`.
- A failing test left as "not mine": it is this change, or it is `/flow:debug-flaky`'s.

## Done

1. **The local gate.** When Workflow → CI says the full suite runs on the PR or in the merge queue,
   run the tests for the diff: Workflow → Specs → changed; without it, the fast loop on every
   changed test file and on the test file each changed source file maps to by the repository's
   layout — a changed file that maps to none (a shared helper, factory, migration, config) means
   the full suite. Else the full suite is CI's. Otherwise (no CI line, or CI does not run the full
   suite), run the full suite (Workflow → Specs). Either way judged by its exit status — a load
   error can print "0 failures" while running nothing. Read the skip count: a skipped test did not
   run.
2. Workflow → Verify, all of it.
3. Coverage: the bar `AGENTS.md` states; with none, every branch the change adds is exercised.

Report each test (`file:line`), the RED line you quoted for it, and the exit status of step 1.
Committing and the PR are `/flow:lfg`'s; this skill produces the diff.
