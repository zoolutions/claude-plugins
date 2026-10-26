---
name: finish-prs
description: Drive open PRs to merge-ready, one at a time, in a given order — merge main in, then rounds of /flow:github-review-pr (conflicts, CI failures, every review thread) until CI is green, no thread is open and the review bot has nothing new; then wait for the user to merge. With `automerge`, merge each PR itself (or queue it) once the gate holds. The last phase of /flow:lfg and the engine of /flow:follow-through.
argument-hint: "ordered PR list (e.g. '292 288 289'); optional 'automerge'; empty = your open PRs, oldest first"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent, Skill, TaskCreate, TaskUpdate, TaskGet, TaskList, ScheduleWakeup, ToolSearch, mcp__cubic__get_pr_issues, mcp__cubic__update_pr_issue_status, mcp__cubic__trigger_pr_review
---

# Finish PRs: $ARGUMENTS

`main` below is the default branch: Workflow → Base when set, else `main`.

Drive a set of open pull requests to **merge-ready**, one at a time, in a fixed order, so parallel
PRs stop churning on each other.

**Read the repository first.** `AGENTS.md` → `## Workflow` holds every fact this skill acts on:
Verify, CI, Review bot, Merge, PR contract, Conflicts, Worktree setup, Main health. A missing label
means "none". When this text says "Workflow → X", it means that line.

**This skill does NOT merge** unless `automerge` was passed. Default: make each PR merge-ready, then
pause and let the user merge; when a merge lands, merge main into the remaining PRs and continue.
In `automerge` mode the gate in 2d is enforced here, not by GitHub (a ruleset often allows merging
with open threads and no approval).

**Unattended runs.** In `automerge` mode there may be no user (an agent under `/flow:follow-through`
runs this). Wherever a step says "ask the user", `automerge` **parks** the PR instead (2f) and moves
on.

---

## Phase 0: Parse the list and the order

- PR numbers, space or comma separated (`292 288`, `#292`, `PR292`): honor the order exactly.
- `automerge` anywhere: merge (or queue, per Workflow → Merge) each PR once 2d holds. Strip it before
  parsing numbers.
- Empty: `gh pr list --author=@me --state=open --limit 100 --json number,title,headRefName,createdAt`,
  oldest first (`--limit` matters: the default 30 silently drops older PRs).

Each merge invalidates the others' merge base; a fixed order syncs each remaining PR once per merge.
One task per PR (TaskCreate). Confirm in one line:
`Finishing N PRs in order: #a → #b → #c. Mode: <pause-for-merge | automerge>.`

## Phase 1: A working tree per PR

Prefer, in order: the current directory if it is on the PR's branch (`/flow:lfg` and
`/flow:follow-through` run this skill where the work happened); an existing worktree on that branch
(`git worktree list`); else create one — `git fetch origin <branch>`,
`git worktree add .claude/worktrees/finish-<PR> <branch>`, then run Workflow → Worktree setup in it
with `<N>` = the PR number. Remember that you created it: Phase 3 removes it after an `automerge`
merge; in default mode it stays (the user merges later), so name it in the Phase 4 report.

Never sync a branch checked out in the user's main working directory unless you were started there.
Never touch `main` directly.

## Phase 2: Per-PR loop

### 2a. Sync with main — merge, never rebase

```bash
git fetch origin main --quiet && git merge origin/main
```

A rebase needs a force-push, which orphans the review bot's inline comments and rewrites a shared
branch. The PR is squashed on merge anyway. "Already up to date" → 2c.

Conflicts: resolve by Workflow → Conflicts first, then semantically (read both sides, keep both
intents). Lockfiles are never hand-merged: take the base's and re-run the resolver. Generated files
are regenerated, never merged. If the right combination is not decidable from the code,
`git merge --abort` and ask the user (default) or park (`automerge`). Run Workflow → Verify for what
the conflict touched, then `git commit --no-edit`.

### 2b. Push

`git push origin <branch>`. A merge commit never needs force; never `--force` a PR branch.

### 2c. One review round

Invoke `/flow:github-review-pr <PR>` (Skill tool). It runs conflicts → CI failures → review threads;
do not re-implement it.

**Rounds.** A round is one review pass, the CI run its push causes, and the review bot's re-review of
the new head. **No round limit.** Every round fixes or answers everything open, whatever its severity
(P1–P3, docs, nits): nothing deferred to a follow-up, nothing offered to the user as a choice. Two
rules keep rounds converging:

- A finding re-raised after it was fixed or answered gets one reply pointing at that commit or
  answer, and is resolved. It is not re-litigated.
- A CI failure that repeats after a fix (same check, same error) means the diagnosis was wrong:
  re-read the log, re-diagnose (consult the advisor), push a different fix. Never the same fix twice.

The only things surfaced to the user (default) or parked (`automerge`) are **blockers outside the
repository**: a runner or registry outage, a missing secret, a GitHub permission. One blocked PR
never blocks the list.

### 2d. Merge-ready

Wait first while anything is still running (Phase 3): every gate reads a finished state.

**Default mode:** `mergeable == MERGEABLE`; every check finished and green
(`gh pr checks <PR> --json name,state,bucket`: each bucket `pass` or `skipping`); `reviewDecision`
not `CHANGES_REQUESTED`; zero unresolved threads (gate 3). The review bot's check is one of the
checks, so its review of the head has posted; a new comment from it is an open thread.

**`automerge` mode:** all of these, cheapest first. `reviewDecision` is ignored (bots never feed it).

1. **Mergeable.** `gh pr view <PR> --json mergeable --jq .mergeable` is `MERGEABLE`. `UNKNOWN` →
   `git fetch origin main`, then `git fetch origin pull/<PR>/head` (its own command, so `FETCH_HEAD`
   is the PR head), then `git merge-tree --write-tree --name-only origin/main FETCH_HEAD`. `CONFLICTING` → 2a.
2. **Checks green.** Every bucket `pass` or `skipping` — stricter than any ruleset on purpose. Trust
   the JSON, not a condensed view (`rtk` files `SKIPPED` under "Failed"). Anything else → 2c.
3. **No open thread, from any author.**

   ```bash
   gh api graphql -F owner='{owner}' -F repo='{repo}' -F pr=<PR> -f query='query($owner: String!, $repo: String!, $pr: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { reviewThreads(first: 100) { pageInfo { hasNextPage } nodes { isResolved } } } } }' --jq '.data.repository.pullRequest.reviewThreads | "\([.nodes[] | select(.isResolved | not)] | length) more=\(.pageInfo.hasNextPage)"'
   ```

   Must print `0 more=false` (`more=true`: page with `after:` as `/flow:github-review-comments` does). Anything else → 2c.
4. **The review bot approved the head** (Workflow → Review bot):
   - **cubic** — its latest review is `APPROVED` **and** its `commit_id` is the PR's `headRefOid`:
     `gh api 'repos/{owner}/{repo}/pulls/<PR>/reviews' --paginate --jq '.[] | select(.user.login | startswith("cubic-dev-ai")) | "\(.submitted_at) \(.state) \(.commit_id)"' | sort | tail -n 1`.
     With the cubic MCP loaded (`ToolSearch` `select:mcp__cubic__get_pr_issues,mcp__cubic__update_pr_issue_status,mcp__cubic__trigger_pr_review`),
     cross-check `get_pr_issues`: `review.status == "completed"`, `hasNewCommitsSinceReview == false`,
     `openIssueCount == 0`; a disagreement fails the gate. `COMMENTED` — even "0 issues" — is not
     approval → 2d′.
   - **coderabbit** — its check is `pass` on the head and gate 3 holds (it does not approve).
   - **none** — skip.
5. **Main is green** — only when Workflow → Merge is a queue (a queue evicts every entry while main
   is red). Run Workflow → Main health; no such line → read the CI status of main's head
   (`gh api "repos/{owner}/{repo}/commits/main/check-runs"`) — never treat a missing line as green. Red → **is this PR the fix?** Run main's failing specs (from
   its red run's `--log-failed`) on this branch: all pass, and they fail on `origin/main` → go on and
   queue it (the queue proves it). Otherwise park (2f) with `main red since <short sha> (#N)`; fixing
   main is its own PR. With a direct squash, a red main shows up in this PR's own checks and is fixed
   in 2c like any failure.
6. **`fable-validator` PASS** on the final diff (2e).

### 2d′. Cubic quiet (`automerge`)

Gates 1–3 hold, cubic's latest review on the head is `COMMENTED` or missing: with the MCP loaded and
no trigger yet for this head SHA, `trigger_pr_review` once, wait for its check (Phase 3), re-run 2d.
Still not `APPROVED` → park: `cubic did not approve <short sha>`. One trigger per head SHA.

### 2e. Hand off

Run the `fable-validator` agent (`flow:fable-validator`) on `git diff origin/main...HEAD` with the
PR's linked issue and the acceptance criteria from the PR body. Skip it only if it already passed on
this exact head SHA (`/flow:lfg` Phase 6.5, no commit since). BLOCK or PASS WITH NOTES → fix every
blocker and note (failing test first for code) and back to 2c. A factually wrong note gets a one-line
rebuttal in the PR body.

Then the final numbers: `/flow:effort <PR> --write` (Skill tool) refreshes the body's
`## Effort & cost`. Its **Where it went** line is the account of the session that did the work: if
that is this session, correct it where the numbers changed the story; if not (a later
`/flow:finish-prs`), never rewrite it — append only what the threads and commits since it was written
show (what the review rounds were about). A body
edit, not a round: no re-review, no validator, no reason to hold a PR that 1–6 cleared. A workflow
the repository runs on `edited` (a PR-contract check) re-runs, though: wait for it (Phase 3) and
re-read gate 2 before merging or reporting merge-ready.

- **`automerge`:** Workflow → Merge, only once 1–6 hold.
  - *squash*: `gh pr merge <PR> --squash --delete-branch --match-head-commit <headRefOid>`.
  - *queue*: `gh pr merge <PR> --match-head-commit <headRefOid>` — no strategy flag, no
    `--delete-branch`. If gh reports it **enabled auto-merge** instead of queueing, a required check
    had not passed: `gh pr merge <PR> --disable-auto` and back to 2d. Then follow the queue (Phase 3).
  - Never `--admin` with a queue (it bypasses the queue and the full suite only the queue runs). With
    a squash, only when Workflow → Merge names it as the fallback for a protection the gate already
    covers (e.g. a required approval), after gates 1–6 hold and the plain merge was refused for that
    protection alone. Never `--auto` (it waits only for required checks). Judge a merge by `gh pr view <PR> --json state,mergeCommit`, never by gh's exit code
    (inside a worktree gh may fail to switch the local branch after a successful merge).
- **Default:** report ✅ merge-ready with the URL and a one-line "what's in it", then wait (Phase 3).

### 2f. Park

For a blocker outside the repository, a review bot withholding approval with nothing open, or a red
main: `gh pr comment <PR>` naming the blocker and what removes it — never a list of findings to fix
later, never options ("merge as is or another round"). Task → `needs-user` with a one-line reason.
Leave the PR and its worktree. Next PR.

## Phase 3: Waiting

**Every wait ends on its own.**

- A foreground wait carries a Bash timeout (at most 600000) and is re-run; never a background
  polling loop. Claude Code refuses a bare `sleep` of a minute or more, so a poll is a counted
  loop (no `timeout` needed, which stock macOS lacks):
  `for i in 1 2 3 4 5 6 7 8; do <check> && break; sleep 60; done; <check>` — 8 min, headroom for
  the checks under the Bash timeout; the trailing `<check>` gives the exit status (the loop alone
  exits 0 when it runs out of tries).
- Its exit condition covers every terminal state: merged, closed, the check or review finished
  either way. Never one exact value that can stop being reachable (a head SHA, a review newer than
  a timestamp): a squash merge or a force-push makes it unreachable forever.
- Never an `until …; do sleep …; done` with `run_in_background`. A background command that waits
  runs under `timeout <seconds>` (or `gtimeout`), at most 2 h.

**CI and the review bot.** With `ScheduleWakeup` (an interactive session): wake after 300 s, re-check
2d — never a busy sleep. Without it (a spawned agent): `gh pr checks <PR> --watch --fail-fast` in the
foreground, re-run on timeout or when a fresh head has no checks yet. No checks to watch (no CI, a
bot that posts none): that loop, its check true once the PR is merged or closed or the bot's
review of the head (gate 4) has posted, either way.

**A merge queue** (Workflow → Merge = queue):

```bash
gh api graphql -F owner='{owner}' -F repo='{repo}' -F pr=<PR> -f query='query($owner: String!, $repo: String!, $pr: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { state isInMergeQueue mergeQueueEntry { state position } autoMergeRequest { enabledAt } mergeCommit { oid } } } }' --jq '.data.repository.pullRequest'
```

Note the time you queued it (`date -u +%FT%TZ`).

- Waiting: wake after 300 s; without `ScheduleWakeup`, find the queue's run —
  `gh run list --event merge_group --limit 20 --json databaseId,headBranch --jq '.[] | select(.headBranch | startswith("gh-readonly-queue/main/pr-<PR>-")) | .databaseId'`
  (none yet: still batching, ask again) — and `gh run watch <id> --exit-status` in the foreground.
- `MERGED` with a `mergeCommit` → merged.
- `OPEN`, not `isInMergeQueue`, `autoMergeRequest` set → never entered: gh armed auto-merge because a
  required check had not passed. `gh pr merge <PR> --disable-auto`, back to 2d.
- `OPEN`, not `isInMergeQueue`, no `autoMergeRequest` → **evicted** when the queue run that failed is
  newer than your enqueue time: read the failure (Workflow → CI names the report, e.g. a marked PR
  comment — a comment edited in place is current only if its `updated_at` is newer than the
  enqueue; else the run's `gh run view <id> --log-failed`). Nothing newer yet → wait one more cycle;
  still nothing → removed by hand: re-run 2d and queue once more. Whether main is red is decided by
  Workflow → Main health, never read from the report: red → gate 5. Green → merge `origin/main` (2a),
  reproduce, fix (failing test first if it exposed a bug), new round (2c). Never re-queue blindly.

**Then advance.** `automerge`: once merged, if you created `.claude/worktrees/finish-<PR>`, undo
Workflow → Worktree setup (drop what it created), `git worktree remove` it and `git branch -D` the
branch; a worktree you were given belongs to its creator. Default: the user merges; on the next turn
re-check `gh pr view <PR> --json state`; not merged → report and stop, never spin. A single PR (the
`/flow:lfg` case) ends at merge-ready. Before the next PR, always fetch and merge the new main (2a).
A PR merged out of order: drop it from the list and sync what is now next.

## Phase 4: Report

| PR | Result | Note |
|----|--------|------|
| #a | ✅ merged / ✅ merge-ready / ⏳ in queue / ⚠️ needs-user | rounds, evictions, the blocker; size and active time against the estimate |

Then what the user must do next.

## Never

- Rebase or force-push a PR branch; sync a branch checked out in the user's tree.
- Merge in default mode; merge on a `COMMENTED` cubic review; `--auto`; `--admin` beyond Workflow → Merge.
- Re-implement `/flow:github-review-pr`, `-failures` or `-comments`: invoke them.
- Let one stuck PR block the rest.
