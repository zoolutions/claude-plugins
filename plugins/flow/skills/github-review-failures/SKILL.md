---
name: github-review-failures
description: Fix every failing CI check on a PR — fetch the failed job logs (and a merge-queue eviction report), diagnose the root cause, fix, verify locally, push. Use when a PR's checks are red; /flow:github-review-pr runs it as its Phase A.
argument-hint: "PR number (e.g. 41 or #41); empty = the current branch's PR"
model: sonnet
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent
---

# CI failures: $ARGUMENTS

`main` below is the default branch: Workflow → Base when set, else `main`.

Repository facts: `AGENTS.md` → `## Workflow` (CI: the jobs, the required check, where the full suite
runs and how a failure is reported; Verify; Specs). PR number as in `/flow:github-review-comments`
Phase 0.

## Phase 1: What failed

`gh pr checks <PR> --json name,state,bucket,link` — every check whose bucket is `fail` or `cancel`. The
run and job ids are in the link (`…/actions/runs/<RUN_ID>/job/<JOB_ID>`). A roll-up gate that fails
because another job failed is fixed by fixing that job. A PR-body contract check is fixed in the body
(`gh pr edit <PR> --body-file …`), not in code.

**Evicted from a merge queue** (Workflow → CI says the full suite runs only in the queue): the PR's own
checks can be green while the queue's run failed. Read the report Workflow → CI names (often a PR
comment with a marker, edited in place: current only when its `updated_at` is newer than the first
CI run on the PR's head, `gh run list --commit <headRefOid> --limit 50 --json createdAt --jq 'map(.createdAt) | min'`;
a commit's own date is its authoring time, not when it was pushed), and the run it links. Workflow →
CI names no report: find the failed queue run itself —
`gh run list --event merge_group --limit 20 --json databaseId,headBranch,conclusion --jq '.[] | select(.headBranch | startswith("gh-readonly-queue/main/pr-<PR>-"))'`
— and read `gh run view <id> --log-failed`.
The failure is on the merge commit — this PR, whatever was ahead of it, and main — so merge
`origin/main` before reproducing. Whether main itself is red comes from Workflow → Main health, never
from the report: red, and the same specs fail on `origin/main` → report it; the fix belongs on main.

Nothing failing and no current eviction report → report and stop.

## Phase 2: Logs

`gh run view <RUN_ID> --job <JOB_ID> --log-failed`; if that is unclear, the full `--log` for the job.
Spec failures: also the run's artifacts (`gh api "repos/{owner}/{repo}/actions/runs/<RUN_ID>/artifacts" --jq '.artifacts[].name'`).

## Phase 3: Diagnose

Per failure: the error, the file and line, which commit on this branch introduced it, and whether it
is code, environment or ordering. Read the failing code before deciding.

## Phase 4: Fix and verify

Order: lint first (fast, deterministic), then schema/migration, then specs, then security and build.
Reproduce locally only the failing tests CI names (Workflow → Specs → fast loop), not the suite,
fix, re-run them, then Workflow → Verify on the changed files.

## Phase 5: Commit and push

One commit per logical fix, `fix(ci): …` saying why it failed; push.

## Phase 6: Report

Which checks failed, the cause, the fix SHA, and which checks are now running. Do not poll in a loop:
the caller (`/flow:finish-prs`) waits.

## Rules

- Fix the root cause; never silence a linter with a disable comment.
- **Fix every failure the PR's CI shows**, one already failing on main included: the PR does not merge
  red, and main gets the fix with it. (A red main that only a merge queue sees is reported, not fixed
  here.)
- **Flaky tests have a cause** (timing, ordering, shared state, environment): find it and fix it. No
  retries, sleeps or skips as workarounds. `/flow:debug-flaky` is the long form.
- The same check failing with the same error after your fix means the diagnosis was wrong: re-read the
  log and fix differently. Never push the same fix twice; never re-run CI blindly.
