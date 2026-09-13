---
name: gate
description: The pre-PR gate. Run before git push or gh pr create and at the verify phase of any implementation workflow. Fresh-context agents review the branch diff against the repo's rules, its lode and the shared checklists; every new test is proven to fail without the change; findings are fixed and re-reviewed until no P1 or P2 remains; then the pass is recorded so the push hook lets the branch through.
argument-hint: "[base ref, default: the profile's default branch] [--rounds N]"
allowed-tools: Bash(*), Read, Grep, Glob, Agent, Edit, Write, Skill
---

# /lode:gate

The author of a diff is the worst reviewer of it. This skill puts the diff in front of reviewers that have never seen the conversation, gives them the repository's own rules and memory, and loops until they are satisfied. It is what an external review bot would do, one round earlier and with the repo's learnings in hand.

The gate reads, in this order: `CLAUDE.md`, every `.claude/rules/*.md`, `lode/workflow.md`, `lode/practices.md`, every `lode/review/*.md`, and the plugin's shared checklists at `${CLAUDE_PLUGIN_ROOT}/checklists/`. If the repo has no `lode/`, stop and run `/lode:seed` first; the gate has nothing to enforce.

## 0. Preconditions

`$ARGUMENTS` carries two optional things: a base ref, and `--rounds N`. The base is the default branch named under **Branches and PRs** in `lode/workflow.md`, or `origin/main` when there is no profile to say. `--rounds N` sets the round limit in step 4 and defaults to 3. Resolve the base, set `BASE` to it, then:

```bash
git fetch -q origin
git status --porcelain            # must be empty: the gate reviews commits, not a dirty tree
git diff --stat "$BASE"...HEAD
mkdir -p lode/tmp/gate && git diff "$BASE"...HEAD > lode/tmp/gate/diff.patch
git log --format='%s%n%n%b' "$BASE"..HEAD > lode/tmp/gate/intent.md
```

If a PR body draft exists (for example `lode/tmp/implementation-notes.md`, or an open PR for this branch via `gh pr view --json body`), append it to `intent.md`. The reviewers judge the diff against the stated intent; an unstated intent is the first finding.

Record the test commands from **Commands** in `lode/workflow.md` — full suite and single file, and `CLAUDE.md` only where there is no profile. The test agent needs the single-file form.

## 1. Fan out

One message, parallel `Agent` calls. Every agent gets the same preamble: the path of `lode/tmp/gate/diff.patch`, the base ref, the path of `intent.md`, the list of context files above, and the instruction to read the context files before the diff. Pass file paths, not contents.

| Agent (`subagent_type`) | Always | Extra input |
|---|---|---|
| `lode:gate-correctness` | yes | |
| `lode:gate-rules` | yes | |
| `lode:gate-claims` | yes | the PR body draft, if any |
| `lode:gate-tests` | yes | the single-file test command, the test directory names |
| `lode:gate-parser` | only when the diff touches parsing | run: `grep -E '^\+.*(%r\{|/\\[A-Za-z]|=~|\.match\(|\.scan\(|StringScanner|\.split\(|Regexp|re\.compile|new RegExp)' lode/tmp/gate/diff.patch` and spawn it if anything matches |

Plugin agents register at session start. If `Agent` answers `Agent type 'lode:gate-…' not found` (the plugin was installed mid-session), spawn `general-purpose` instead and open the prompt with: "First read `${CLAUDE_PLUGIN_ROOT}/agents/<name>.md` and adopt it as your role, method and output format exactly." The result is the same agent; only the registration differs.

If the `pstack` plugin is installed, also invoke `pstack:interrogate` on the same diff; its reviewers run on different models, which is a signal the agents above do not have. Merge only its **Act on** findings.

## 2. Merge and verify

Collect every finding into `lode/tmp/gate/findings.md` with: id, agent, severity, file:line, claim, failing case, confidence. Deduplicate findings that describe the same defect from two agents; keep the higher severity and note both sources.

Then verify each P1 and P2 yourself before touching code. Fresh reviewers are wrong sometimes, and usually half-right: the reported failure is not the one that happens, but there is one. Read the code, construct the failing case, run it where you can. Record the verdict per finding: **confirmed**, **confirmed differently** (say how), or **rejected** with the one-line reason. A rejection with no reason is not allowed.

## 3. Fix

For each confirmed P1 and P2, in this order:

1. Write the failing test first, or extend the existing one, and see it fail.
2. Fix the root cause, not the line the finding points at. A finding about one shape usually has siblings in the same file; the correctness agent lists them, fix them together.
3. Apply the repo's own rules to the fix (additive in upstream-owned files, argv arrays for shell-outs, whatever `CLAUDE.md` says).
4. Run the affected test file, then the full suite.
5. Commit with a conventional message that names the finding: `fix: <what>` with the failing case in the body. One commit per logical fix. Never amend or rewrite commits that are already pushed.

P3 findings: fix when the fix is a line or two, otherwise record them as deferred with a reason. A deferred P3 goes in the PR body so a reviewer can disagree.

## 4. Loop

Regenerate `diff.patch` and re-run only the agents whose findings were fixed, plus `gate-rules` always (a fix can break a rule). Stop when a round produces no confirmed P1 or P2, or after the `--rounds` limit from `$ARGUMENTS` (default 3). Hitting the limit is a failure: report it and do not record a pass.

## 5. Record the pass

Only when the working tree is clean and the last round was clean:

```bash
cat > lode/tmp/gate/report.md   # rounds, findings table with verdict and outcome, mutation results, tests run
printf 'tree=%s\nreport=lode/tmp/gate/report.md\nat=%s\n' "$(git rev-parse 'HEAD^{tree}')" "$(date -u +%FT%TZ)" > lode/tmp/gate-passed
```

The push hook compares `tree=` with `HEAD^{tree}`; any commit after this point invalidates the pass and the gate must run again (a rerun after a small fix is one round, not three).

## 6. Learn

Every **confirmed** finding is a lesson the repository has now paid for. Invoke `/lode:learn gate` before opening the PR so the rule lands in `lode/review/` in the same PR as the fix. Rejected findings that were plausible teach too: a one-line "not a bug because …" in the relevant `lode/review/` file stops the next reviewer from raising it.

## 7. Report

End with a section the caller pastes into the PR body:

```
## Gate
Rounds: N. Findings: X confirmed and fixed, Y rejected, Z deferred.
- [P1] <claim> — fixed in <sha>, test <file>:<name>
- [P2] <claim> — rejected: <reason>
- [P3] <claim> — deferred: <reason>
Mutation check: all new tests fail on base | <exceptions>
Tests: <command> green
Learned: <lode/review files touched>
```

## Escape hatch

`LODE_SKIP_GATE=1 git push` bypasses the hook. Use it for a revert, a hotfix, or a docs typo, and say so in the PR body. Using it on a feature branch defeats the purpose: whatever the gate would have caught goes to the human reviewer, or to production, instead.
