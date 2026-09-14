---
name: debug-flaky
description: "Use when a test looks intermittent — an Actions run that's red where others were green, a PR check that failed and passed on retry, or a locally observed flake. Takes a failed run URL, a PR, or a test path; drives evidence → forced reproduction → root cause → a stress-proofed fix → knowledge capture. Never masks with retry, sleep, skip, a widened timeout or a loosened assertion."
argument-hint: "<run URL | PR | test path>"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
---

# /lode:debug-flaky

The deliverable is the mechanism, stated in one sentence, then a fix proven by forcing the failure on the old code and watching it disappear on the new one. Never a `retry`, a `sleep`, a `skip`, a widened timeout, or a loosened assertion — those hide the bug; it resurfaces somewhere more expensive.

## 0. Read the profile

Read `lode/workflow.md`, and `lode/lode-map.md` for the area the failing test covers. If the profile does not exist, say so plainly, derive what you need from `CLAUDE.md` and `.claude/rules/*.md` directly, and tell the user this repo has no profile — run `/lode:seed workflow`. Otherwise pull, by exact heading:

- **Commands** — the single-file and full-suite test invocations; the single-file form is what every rung below runs
- **CI** — which workflow files run, the matrix dimensions, how to fetch a failed job's log, and any documented not-this-branch failure
- **Flake sources** — the repository's *actual* sources of non-determinism, named already. Start here, not from a generic taxonomy
- **Branches and PRs** — the default branch, work-branch naming, commit convention

## 1. Parse the input

- **Run URL/ID** → Phase 2 directly.
- **PR number** → `gh pr checks <n>` to find the failed run(s), then Phase 2.
- **Test path** (a locally observed flake, no CI run) → skip to Phase 3 with what you were told; there is no job log, only the test.

## 2. Evidence

```bash
gh run view <run> --json jobs --jq '.jobs[] | {name, conclusion, databaseId}'
gh run view <run> --job <job_id> --log-failed   # or the repo's CI-specific fetch, from the profile
gh run view <run> --json headBranch,headSha
```

Pull out: the failing test name(s) and file, any printed seed or ordering key, which matrix cell (the profile's CI dimensions), and the exact commit. Then the question that decides everything else:

**Is the default branch green on this same code?** Find the last default-branch run that built this commit or its ancestor and check its conclusion for the same cell. Red in every cell on every branch, including default → a regression, not a flake; fix it as one, on the branch that introduced it. Red in one cell only, or red here and green on default at the same commit → genuinely intermittent, continue below. Green on a re-run of the identical commit and cell → confirms intermittency; it does not yet tell you the mechanism.

**If the defect predates this PR** (default branch is red on the same code, independent of what this PR changed), the fix branches off the default branch per **Branches and PRs**, not off the PR's branch — the PR did not cause it and should not carry it.

## 3. Consult memory before hypothesising

- `lode/review/*.md` for a rule already written about this file or pattern
- `git log --oneline -i --grep=flak --grep=retry --grep=sleep --grep=timeout -20` — a prior flake-hardening commit tells you what shape this codebase's races already take
- `gh issue list --label flaky-test --state all --search "<test name>"` — work under an existing issue rather than opening a duplicate

## 4. Reproduce by forcing, never by looping

Loop-until-it-fails proves a failure exists; it proves nothing about why, and a hundred green iterations prove nothing either. The **Flake sources** heading names this repository's actual suspects (a live network call, per-test process isolation, a class-level accessor, wall-clock or ordering assumptions, GC-collectible temp objects) — start there, and force the exact one you suspect:

- suspected GC/finalizer race → force the collection at the point the race window opens instead of hoping it fires; for instance, a Ruby `Tempfile` whose object is dropped: call `GC.start` between the helper and the read
- suspected scheduling or startup race → start the two processes at once and hold them at the same barrier, rather than running them in sequence and calling it a test
- suspected seed-dependent ordering → run with a fixed seed that reproduces it, and a second fixed seed that does not, so the seed is the variable
- suspected order/state leakage → run with the failing run's exact seed, or the two specific test files back to back
- suspected network flake → replace the call with a stub that returns the exact failure mode (timeout, reset, 429) the log showed
- suspected thread/process leakage → assert on the resource directly (a thread list, a tmpdir, an fd count) at the point of failure, not on the symptom three calls later

A forcing script that runs the real code path against the current (broken) implementation and asserts the wrong outcome is your reproduction. If nothing you force reproduces it, you have not yet identified the source — go back to **Flake sources**, do not fall back to a bare loop.

Only once a forcing script exists, use a loop as a secondary confidence check, judged by exit code, never by grepping output:

```bash
status=0
for i in $(seq 1 10); do <single-file test command from Commands> || { echo "FAIL i=$i"; status=1; }; done
exit "$status"
```

## 5. Root cause

Write the mechanism in one sentence before touching code: *what* races with *what*, over *what* window. One example of the bar: "the helper returned a `Tempfile`'s path and dropped the object, so GC could unlink the file before the caller read it". Another: "both workers derive the temp path from the same fixture name, so whichever finishes second truncates the file the first is still reading". Both are precise enough that the forcing script in Phase 4 is just the sentence turned into code. If you cannot write the sentence, you have not found it yet; do not proceed to a fix.

## 6. Fix — remove the non-determinism, nothing else

The smallest change that closes the race: hold the reference the GC was collecting, restore the class-level accessor in `ensure`, move the call inside the repo's retry helper, pin the version that drifted. Match the file's ownership rule from the profile's **Layers** heading (additive in an upstream-owned file, whatever shape a generated or vendored file requires).

Hard rules, no exceptions:

- no `retry` wrapped around the assertion
- no `sleep`
- no `skip`
- no widened timeout
- no loosened or removed assertion
- no `rescue` that swallows the error instead of fixing what raises it

A bounded retry belongs in the application's own retry helper for a genuinely external operation — never in the test, never around the code under test.

## 7. Stress-prove in both directions

Run the Phase 4 forcing script against the pre-fix code and the post-fix code and show both outcomes — the old code fails the way the mechanism predicts, the new code passes:

```bash
git stash                              # or check out the commit before the fix
<forcing script>                       # must fail, and fail the predicted way
git stash pop                          # or check out the fix
<forcing script>                       # must pass
```

Then the exit-code loop from Phase 4 at the N under **Verification** → *Stress iterations for a flake proof* (fewer iterations for anything that costs real network or process time), plus the original failing run's exact seed/cell if Phase 2 captured one. Finish with the profile's **Commands** full suite.

## 8. Siblings

The bug you just named has a shape — a value dropped before use, an accessor never restored, a call outside the retry helper. Grep the file, and the files **Layers** lists in the same layer, for the same shape before moving on. Fix siblings found this way in the same commit; note ones you decide not to touch and why.

## 9. Record

Invoke `/lode:learn "<the finding in words>"`: the mechanism, the file and method, the forcing script as the proof, "confirmed" verdict. It writes the rule into `lode/review/<area>.md` so the gate catches a regression of the same shape, and promotes it to the shared checklists if the shape isn't specific to this repository. If the fix cannot ship now, open a `flaky-test`-labeled issue with the mechanism and the forcing script instead of leaving a bare "known flaky" note; if it ships now and an issue already tracked this, close it in the PR.

## 10. Ship as its own PR

This is a fix like any other — it gets its own branch and its own PR, never folded into whatever else is in flight:

```bash
git fetch origin && git switch -c fix/<slug> origin/<default-branch-from-profile>
# commit the fix, the new/updated test, and the /lode:learn write, per Branches and PRs
```

Run `/lode:gate` before pushing. Push and open the PR per **Branches and PRs**; the body states the one-sentence mechanism, the forcing-script proof (fails old, passes new), and the gate report.
