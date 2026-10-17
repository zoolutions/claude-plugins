---
name: debug-flaky
description: Root-cause an intermittent test failure from a failed CI run, a PR or a test path — evidence, a forced reproduction, the mechanism in one sentence, a fix proven in both directions. Use when a test fails only sometimes; never masks it with a retry, sleep, skip or loosened assertion.
argument-hint: "<Actions run URL or ID | PR number | test path>"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent, Skill
model: opus
---

# Debug flaky: $ARGUMENTS

A flaky test has a cause. Deliver the **mechanism in one sentence**, a forcing reproduction that
fails on the old code and passes on the new, and the fix. Never a `retry`, `sleep`, `skip`, widened
timeout, loosened or deleted assertion, or swallowing `rescue`. A bounded retry around a genuinely
external operation belongs in the code's own retry helper, never around the assertion.

**Read the repository first.** `AGENTS.md` → `## Workflow`: **Specs** (fast loop, full suite, how
two runs are isolated), **CI** (jobs, where the full suite runs, the failure report), **Main health**,
**Verify**, **PR contract**. A missing label means "none".

## 0. Input

- **Run URL or ID** → 1. A URL for another repository stops here: the fix lives in that checkout.
- **PR number** → `gh pr checks <PR> --json name,state,bucket,link`, the failed run(s) → 1. A PR
  evicted from a merge queue: the report Workflow → CI names.
- **Test path** (seen locally) → 2, with what the user saw.

## 1. Evidence

`gh run view <run> --json jobs,headBranch,headSha,event`, then `--job <id> --log-failed` (`--log`
when too thin). Extract: the failing tests; the seed or order key; every randomised value the suite
prints (time zone, locale, port); the job's file list when CI splits the suite; the matrix cell; CI's
own re-run of the failures, if any; the commit; the noise before the failure (start-up, pulls, network).

- Red in **every** cell → deterministic, a regression. Red in **one** dimension (a version, an OS, a
  dependency set) → a compatibility break, unless the error is transport or timing.
- CI's re-run of the failures alone **passed** → the test needed company (order, shared state);
  **failed again** → self-contained: suspect a regression.

## 2. Is it flaky at all? Before any taxonomy

1. Run the failing tests 3× on the run's commit (fast loop, the seed). Red every time → a regression:
   `git log` the test **and** the code under test; often two PRs green apart collide together.
2. Did the test **run** on the builds you believe were green? A split suite can mis-schedule files; a
   missing tool turns tests into skips. Grep the green run's log for the file; read the skip count.
3. Main red on the same code (Workflow → Main health)? It predates this branch; still fixed (step 7).

Any hit is the answer: say plainly it was never a flake, and fix the regression.

## 3. History

`git log --oneline -i --grep=flak --grep=race --grep=timeout --grep=retry -20` shows the shapes this
codebase's races take; that log and the PR bodies are the record (no notes file). `git blame` the
test for the invariant it fences. `gh issue list --state all --search "<test name>"`: close it here.

## 4. Classify

| Class | Tell | Suspects |
|---|---|---|
| Order / state leakage | passes alone, fails after certain files; the seed reproduces | globals, class-level settings, env vars, singletons, caches, rows not cleaned, a `chdir` not undone |
| Time | clusters at boundaries (midnight, month end, DST) or in certain time zones | the real clock, timeout arithmetic, a randomised zone |
| Random data | generated values collide; an unordered result asserted in order | factories, ordering by a random id, a missing `ORDER BY` |
| Concurrency | errors in teardown, a held resource, a stuck child | unjoined threads or processes, a window between two calls, a finaliser or GC |
| Shared resource | parallel workers or shards share a database, queue, port or temp path | per-run isolation (Workflow → Specs) |
| External service | timeouts, resets, 429/5xx from a live call | a call outside the retry helper, a live call where a stub belongs, a version not pinned |
| Async UI | an assertion right after an action races the update | an immediate read where a waiting matcher on the final state belongs |
| Stub fragility | a stub that silently stops intercepting when internals change | make it self-verifying: assert it was called |
| CI divergence | fails on CI, never locally | images, versions, env vars, installed tools: diff CI against local |

## 5. Reproduce by forcing, not looping

A loop that runs until it fails proves a failure exists, not why. Force the suspect:

- order or state → the failing seed, or the two files back to back; bisect the order if the runner can;
- time → freeze the clock at the boundary, run under the zone the log printed;
- concurrency → hold both sides at a barrier, or force GC where the window opens;
- external service → stub the call to return exactly the failure the log showed;
- shared resource → run two workers, or the suspect test, at once;
- a leak → assert on the resource itself (threads, file descriptors, temp files, rows) where it fails.

The forcing script runs the real code path and fails on the current code the way the log did.
Nothing forces it → wrong suspect: back to 4, never to a bare loop. Then a second check, judged by
exit status (a load error can print "0 failures" while running nothing):

```bash
status=0; for i in $(seq 1 10); do <fast loop> || { echo "FAIL $i"; status=1; }; done; exit $status
```

## 6. Root cause

Instrument before hypothesising: print the state at the assertion, log every call a suspect stub
receives. Map the moving parts (hooks, shared helpers, fixtures, global configuration): the failure
point is rarely the fix point. Then write the mechanism — what races with what, over which window:
"the helper returned a temp file's path and dropped the object, so GC could delete the file before
the caller read it". No sentence, no fix.

## 7. Fix

The smallest change that removes the non-determinism, at the root (test infrastructure, the code
under test, or both), in a form that cannot be silently defeated: state restored in teardown, an
explicit order, a self-verifying stub, a waiting matcher, an exact version, a per-run resource. Grep
for the same shape (same file, same helper, same layer) and fix those siblings in the same commit.

- **From a PR's CI** (or under `/flow:github-review-pr`): fix on that PR's branch, even when the
  flake predates it. The PR does not merge red; main gets the fix with it.
- **Standalone** (a run on main, a local flake): its own branch off a fresh main and its own PR per
  Workflow → PR contract. Report the URL.

The only exit without a fix is a cause outside the repository (a runner or registry outage, a missing
secret): report it as a blocker, with the evidence.

## 8. Prove it

1. The forcing script fails on the pre-fix code as the mechanism predicts, and passes on the fix.
2. If the test fences a regression, reintroduce the original bug for a moment: it must go red.
3. The loop: 10 consecutive green runs with fresh seeds (3 when each run costs network, containers
   or a browser), by exit status, plus the original seed and cell.
4. The full suite (Workflow → Specs) and Workflow → Verify.

The commit message and PR body carry the mechanism sentence, the class, the forcing proof (fails
old, passes new), the stress count, the siblings fixed and `Closes #N` for an existing issue.
