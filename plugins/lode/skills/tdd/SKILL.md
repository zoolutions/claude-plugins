---
name: tdd
description: Use when implementing any feature or fixing any bug. Enforces RED -> GREEN -> REFACTOR: write the failing test first, run it, watch it fail for the right reason, implement the minimum, then refactor with the test still green. Reads the repository's test framework, stubbing convention and fixture convention from lode/workflow.md rather than assuming one.
argument-hint: "<behaviour to implement>"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
---

# /lode:tdd

A test written after the code it tests proves nothing — it was shaped to fit what already exists. This skill enforces the order: RED, then GREEN, then REFACTOR, for the behaviour named in `$ARGUMENTS`, every cycle, no exception for "this one's obvious."

The skill has no framework of its own — it takes one from this repository's own profile.

## 0. Load the profile

Read `lode/workflow.md`, and `lode/lode-map.md` for the area you are about to test — its entry points at the summary and the `lode/review/` rules for that code. Its **Commands** table gives the fast-loop (one file) and full-suite commands. `CLAUDE.md` and `.claude/rules/*.md` give the test framework, the stubbing convention and the fixture convention — read whichever files the profile points at rather than re-deriving them from scratch. Nothing in this skill names a framework or a stubbing tool; use whatever those files say for this repository.

If `lode/workflow.md` does not exist, say so before doing anything else, then fall back to `CLAUDE.md` and `.claude/rules/*.md` directly for the same facts. This cycle still runs from the fallback, but tell the user `/lode:seed workflow` builds the profile so the next workflow skill doesn't re-derive it.

## 1. RED — write the failing test

Write the test for the named behaviour first, in the file, framework and fixture shape the repository's own rules call for. Before running it, know what "fails for the right reason" looks like here:

- a missing method or class throws — an exception, not an assertion diff
- a collection that should hold results but doesn't comes back empty
- a value that's simply wrong prints an assertion diff between expected and actual

Run it with the fast-loop command from **Commands**. Read the actual output and quote the line that proves it — the exception, the empty collection, or the diff. A failure for the wrong reason (a typo in the test, a fixture that won't load, a missing require) is not RED; fix the test until the failure is the missing behaviour, then run it again.

This is the same check `/lode:gate`'s test agent runs mechanically later, against the commit instead of the terminal: it applies only this test to the base branch and confirms it fails there. A test never watched fail might pass on the base too — an assertion too loose to fail, a fixture that already contains the answer. Watching it fail now is cheaper than the gate finding it.

## 2. GREEN — the minimum that passes

Write only enough to pass the test just written — not the sibling case, not the feature visible three steps ahead, not a cleanup of something nearby. Check where the change lands against **Layers**: new behaviour goes where that table says it's owned, and a file marked upstream-owned, generated or vendored gets touched only the way its edit rule allows.

Run the fast-loop command again. Green for the right reason: the assertion that failed now matches — not a test made vacuous to get there (an assertion deleted, a condition loosened, a `skip` added with no stated reason all count as failures of this step, not passes).

## 3. REFACTOR — with the test still green

Improve the implementation and the test with the suite green, then run the fast-loop command once more to prove the refactor changed nothing observable. This is also where the change gets checked against **Shapes**: each input, state and environment the profile lists is either exercised by a test now, or genuinely untouched by this change — not assumed fine.

## Every test, every cycle

Carry these into RED regardless of which behaviour is under test — they are what makes a green run mean something:

- **Assert every half of the outcome.** A path with two or more observable effects — two records changed, a message and a status, both sides of a split — needs both asserted. One passing assertion on one half is not evidence for the half it didn't check.
- **Stub at the boundary the code owns**, never inside the thing under test. The stub replaces the network call, the client method, the external process — not a private method of the class being tested.
- **Exact versions in anything live.** A test against a real dependency pins the exact version or response it expects, so an upstream release can't silently change what "pass" means.
- **Isolation for anything that writes.** Disk, a shared table, a class-level accessor — anything a test writes to runs inside an isolated path or resource and restores what it changed afterward.
- **Fixtures fork, they don't mutate.** A new shape gets a new fixture named for the shape; an existing fixture other tests rely on is never edited to fit this one.

## Forbidden, always

- `retry` or `sleep` to make a flaky assertion pass — a flaky test has a root cause; that's `/lode:debug-flaky`'s job, not this cycle's
- `skip` with no stated condition and reason
- loosening an assertion instead of fixing the code or questioning the test's premise
- testing implementation — a private method, a regex's internals, a call count — instead of the behaviour a caller actually depends on

Any of these in a diff is exactly what `/lode:gate`'s test agent flags at P1. Catching it here is the same finding, earlier and cheaper.

## 4. Full suite, then verify

Before calling the cycle done, run the full-suite command from **Commands** — note whether it needs network or services, and don't skip that part of it to save a round trip. If the profile's **Constraints** table lists a shortcut that looks tempting here — a mock this repository has already rejected, a suggestion a past reviewer pushed back on — that table is the reason not to take it. Finish with the manual check under **Verification** when this is the kind of change a person would actually look at, not just a green suite.

## Handoff

TDD produces the diff; it doesn't clear it. Run `/lode:gate` before `git push` or `gh pr create` — its test agent re-proves every "fails on base" claim this cycle made by hand, mechanically, on the tree as committed.
