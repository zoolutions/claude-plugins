---
name: lfg
description: The full engineering workflow for one issue or description, from a fresh branch to a merge-ready PR — understand, explore, plan, TDD, verify, Fable validation, PR, then /flow:finish-prs until CI is green and every review thread is answered. Never merges. Use for any non-trivial feature or fix.
argument-hint: "GitHub issue number/URL, a plan file, or a description"
model: opus
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent, Skill, TaskCreate, TaskUpdate, TaskList, ScheduleWakeup, ToolSearch, mcp__cubic__get_pr_issues, mcp__cubic__update_pr_issue_status, mcp__cubic__trigger_pr_review
---

# /flow:lfg — $ARGUMENTS

`main` below is the default branch: Workflow → Base when set, else `main`.

One pass from nothing to a merge-ready PR. The phases are the same everywhere; every fact they act
on comes from the repository. **Read `AGENTS.md` first**, its `## Workflow` section above all
(Verify, Specs, CI, Review bot, Merge, PR contract, Conflicts, Worktree setup, Release). "Workflow → X"
below means that line; a missing line means none. AGENTS.md's never-do rules bind every phase.

## Phase 0: Branch

1. `git fetch origin main`
2. **Already prepared?** An orchestrator (`/flow:follow-through`) may have created the branch in a
   worktree. Keep it, and say so, only when all hold: `git branch --show-current` is
   `issue-<number>-…` for this issue, `git status --porcelain` is empty, `HEAD` equals `origin/main`.
3. Otherwise `git switch -c issue-<number>-<slug> origin/main` (`feature/<slug>` without an issue).
   Works in a worktree too, where `git checkout main` fails.

## Phase 1: Understand

- Issue: `gh issue view <n> --json title,body,labels,comments`. Plan file: read it whole. Keep the
  issue's type/area labels for the PR (Workflow → PR contract says how labels work); never edit the
  issue's own labels.
- Write acceptance criteria as GIVEN / WHEN / THEN. Do not go on until you can.
- Comprehension gate — one line each: the problem; why it matters; what changes for the user; edge
  cases nobody mentioned; the code path or data flow. Can't answer one → investigate more.
- TaskCreate the steps.

## Phase 2: Explore

Find the related files (an Explore agent with `model: haiku` for broad sweeps), read how similar
features are built, the integration points, and the existing tests.

## Phase 3: Plan

Files to change and why; new files; migrations; the tests to write first. A library limitation is
never worked around silently: `/flow:plan upstream <owner/repo> <limitation>`, linked from the PR.

## Phase 4: Implement (TDD)

A bug fix runs Phase 5 first: the root cause decides where the failing test and the fix belong.

**Deviation log from the first edit.** The moment reality forces a choice the plan did not settle,
add one line to `implementation-notes.md` at the repo root: deviation (planned X, did Y, because Z),
discovery (a fact the plan did not know), or judgment call (a choice the user might have made
differently). Take the conservative option and keep going. Never commit the file.

Per logical unit: a failing test first (run it, see it fail for the right reason) → the minimum code
to pass → refactor green → Workflow → Verify on the changed files. `/flow:tdd` is the long form.

## Phase 5: Root cause (bug fixes — before Phase 4)

Trace the failing value back to where it was created; `git log -S` / `git blame` for why the code is
the way it is; map every caller; five whys to the earliest point the error could be prevented, and
fix there. Never `rescue nil`, a blind `&.`, a presence guard, `find` → `find_by`, or an early return
that hides the cause.

## Phase 6: Verify

All of Workflow → Verify, and the specs for what changed (Workflow → Specs). Then re-read the
request: would the requester call it done; is it the root cause; do the tests prove it?

## Phase 6.5: Fable validation

Spawn `flow:fable-validator` with the issue, the acceptance criteria and the base branch. BLOCK → fix
every blocker (failing test first) and run it again. PASS WITH NOTES → fix every note the same way
and run it again; a factually wrong note gets a one-line rebuttal in the PR body. Nothing is accepted
as a risk or deferred. Put its verdict line and its "Not verified" list in the PR body. No PR before
PASS, or PASS WITH NOTES with every note fixed or rebutted.

## Phase 7: Commit and PR

Conventional commit (`feat(scope): …`), body says why. Push with `-u`. `gh pr create` with the labels
from Phase 1 and every section Workflow → PR contract requires, in its order. The body ends with
`## Deviations & judgment calls`, copied from `implementation-notes.md` ("None — the plan held." if
empty); then delete the file. A UI change attaches before/after screenshots
(`gh pr comment <n> --attach '<file>#<alt>'`) when the PR contract asks for them.

## Phase 8: Finish the PR — never merge

Run `/flow:finish-prs <PR>` (Skill tool) in its default mode: merge main in, then rounds of conflicts →
CI → every review thread (the review bot's included), waiting on CI and the bot between rounds, until
merge-ready. Every finding is fixed or answered in its round. `/flow:lfg` never merges: the user does.
Only an orchestrator's brief (`/flow:follow-through`) runs this phase as
`/flow:finish-prs <PR> automerge`. A blocker outside the repository ends the phase: name it and what
removes it.

## Phase 9: Close-out

End the final message with:

1. **The decisions, not the diff** — the 3–5 non-obvious choices someone maintaining this must know,
   deviation-log items first.
2. **Three merge-gate questions** the user should be able to answer before merging; offer a
   walkthrough if any is not obvious.
