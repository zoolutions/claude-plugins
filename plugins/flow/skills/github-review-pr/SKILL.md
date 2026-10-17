---
name: github-review-pr
description: One full review pass on a PR, strictly in order — merge conflicts with the base, then CI failures (/flow:github-review-failures), then every review thread (/flow:github-review-comments). Use when a PR needs to get to green and thread-free; /flow:finish-prs runs it once per round.
argument-hint: "PR number (e.g. 156 or #156); empty = the current branch's PR"
model: opus
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent, Skill, ToolSearch, mcp__cubic__get_pr_issues, mcp__cubic__update_pr_issue_status
---

# Full review pass: $ARGUMENTS

Three phases, in this order, never interleaved:

1. **A0 — conflicts**: CI only matters for the code that will merge; a conflict resolution changes code
   and invalidates any run you just read.
2. **A — CI failures**: before comments, because every comment fix pushes a new run that buries the
   original failure logs.
3. **B — review threads.**

The only reverse moves: a new failure during B → back to A; a new conflict mid-pass (the base moved)
→ back to A0. Repository facts: `AGENTS.md` → `## Workflow` (Conflicts, Verify, CI, Review bot).

## Phase 0: The PR

As in `/flow:github-review-comments` Phase 0. Already merged → report and stop.

## Phase A0: Conflicts

`gh pr view <PR> --json mergeable,mergeStateStatus,baseRefName`:

| `mergeable` | Action |
|---|---|
| `MERGEABLE` | Phase A |
| `UNKNOWN` | Don't poll. `git fetch origin <base>` and `git fetch origin pull/<PR>/head`; check both refs resolve (`git rev-parse --verify origin/<base>^{commit}`, `git rev-parse --verify FETCH_HEAD^{commit}`); `git merge-tree --write-tree --name-only origin/<base> FETCH_HEAD`. Clean → Phase A; conflict output → resolve |
| `CONFLICTING` | Resolve |

**Resolve:**

1. Be on the PR's branch with a clean tree: stay put if the current directory already is (a
   `/flow:finish-prs` or `/flow:follow-through` worktree), else `gh pr checkout <PR>`. Dirty tree →
   stop and ask (unattended: park). Stash nothing.
2. `git fetch origin <base>` and **`git merge origin/<base>`** — merge, never rebase (a rebase needs a
   force-push on a shared branch).
3. Every conflicted file, semantically: read both sides, keep both intents. Workflow → Conflicts has
   the per-file rules; the defaults when it is silent:
   - lockfiles: never hand-merged — take the base's file and re-run the resolver;
   - generated files (schemas, compiled assets): regenerate from both sides' sources;
   - changelogs and append-only registries: union, base order first, no duplicated headings;
   - never a blanket `--ours`/`--theirs` on a source file.
4. Workflow → Verify for what the conflict touched, before pushing.
5. Commit the merge (git's message; a body line for any non-obvious choice) and push — never force.

A conflict whose right combination is not decidable from the code (both sides rewrote the same logic)
→ stop and ask (unattended: park). A guessed resolution that compiles is worse than a question.

## Phase A: CI failures

Run `/flow:github-review-failures <PR>` (Skill tool). Exit when CI is green on the latest commit, or
running with nothing failed on it, or a failure persists whose cause is **outside the repository** (a
runner or registry outage, a missing secret) — report that blocker and go on. A failure from code is
fixed here, a flaky test or one already failing on main included. A fix that did not take (same check,
same error) means the diagnosis was wrong: re-diagnose, push a different fix, stay in Phase A.

## Phase B: Review threads

Run `/flow:github-review-comments <PR>`. Exit when every thread — the review bot's included — is
fixed or answered and resolved, and the fixes are pushed.

## Phase C: Report

Re-check mergeability (the base can move during a long pass; a new conflict → A0). Then: A0 (conflicted
files and how each was resolved, or "clean"), A (failures fixed, SHAs), B (accepted with SHAs, pushed
back with reasons, unresolved count — 0), end state (mergeable, CI on the head), and anything still
running.
