---
name: follow-through
description: Drive an epic (or any issues) from plan to merged, unattended — dependency waves, /flow:lfg per issue in its own worktree through one Opus agent each, /flow:finish-prs automerge on every PR, and upstream library fixes carried through to a release and an adoption issue. Parks what it cannot settle and carries on with whatever does not depend on it.
argument-hint: "epic or issue number(s), e.g. '#539' or '540 541'; --dry-run prints the waves only"
model: opus
allowed-tools: Bash(*), Read, Glob, Grep, Agent, Skill, TaskCreate, TaskUpdate, TaskList
---

# /flow:follow-through — $ARGUMENTS

`main` below is the default branch: Workflow → Base when set, else `main`.

`/flow:lfg` takes one issue to a merge-ready PR and stops. This takes one issue or a whole epic to
merged: it orders the issues by their dependencies, runs `/flow:lfg` on each in its own worktree with
`automerge` on its last phase, and follows any upstream fix through to a release. A run left alone
ends with every issue merged or parked with a reason, and one table.

You are a **thin orchestrator**: resolve the order, prepare a worktree per issue, spawn one agent per
issue, keep the books. All repository knowledge lives in `/flow:lfg`, `/flow:finish-prs`, the
commands they call, and `AGENTS.md` → `## Workflow`. All `gh api` paths use `{owner}`/`{repo}`.

## Phase 0: The work graph

### 0.1 Classify

`gh issue view <n> --json number,title,state,labels,body` for each argument.
**Umbrella**: labelled `epic`, or task-list items `- [ ] #N` / `- [x] #N`, or sub-issues
(`gh api 'repos/{owner}/{repo}/issues/<n>/sub_issues' --jq '.[] | "\(.number) \(.repository_url)"'`).
Its children are those items and sub-issues, classified the same way. **Leaf**: anything else. Only
leaves run. A leaf whose plan would land as several PRs (phases, "one PR per step") is split before
the waves: `/flow:plan split <n> --unattended` (Skill tool) makes its steps sub-issues, and it is an
umbrella from then on. One PR per issue: a PR that only `Refs` its issue leaves it open forever.
Under `--dry-run` nothing is split: list it as `todo (would split into steps)`, one leaf.

### 0.2 Each leaf's umbrellas

The umbrella it was reached from; its GitHub parent
(`gh api 'repos/{owner}/{repo}/issues/<n>/parent' --jq '"\(.number) \(.repository_url)"'`, 404 = none);
and the **first** `#N` after `Part of`, up to the next `;` or `.`. Read an umbrella only to apply 0.3:
**its other children do not join the run**. "Part of" names an umbrella, never a prerequisite.

### 0.3 Prerequisites

Join wrapped lines within a paragraph or list item first. Phrases are case-insensitive; a sentence
ends at `.` or `;` + space, or at the end of its item; a `.` inside backticks does not end one. Only
this repository's issues count: an `owner/repo#N`, or a sub-issue/parent in another repository, is
listed in the report as not followed.

In a **leaf's** body, an edge `N → leaf` for: `builds on`, `depends on`, `blocked by` (every `#N` to
the end of the sentence); `after #N` (the `#N` right after the word); `#N` / `(#N)` followed by
`lands first` / `lands before`. In an **umbrella's** body: a `lands first` sentence about `#N` makes
`N` a prerequisite of every other child in the run; a sentence naming a child and its prerequisite
adds that edge. Nothing else makes an edge (not "in order", not a numbered list, not a dependency
without a `#N`).

A **closed** prerequisite is satisfied. An **open** one not in the run joins it as a leaf and is read
the same way. Repeat 0.2–0.3 until nothing joins.

### 0.4 Status and resume

First match wins:

| Found | Status | Runs |
|---|---|---|
| issue closed | `done` | nothing |
| an open PR closes it | `resume-pr #<pr>` | `/flow:finish-prs <pr> automerge` |
| worktree `.claude/worktrees/follow-<N>` or branch `issue-<N>-*` with commits ahead of `origin/main` or uncommitted changes, no PR | `resume-worktree` | `/flow:lfg` as lfg-resume (skip Phase 0, rebuild Phases 1–3, continue Phase 4), then finish |
| none | `todo` | the full run |

Open PRs closing an issue (GitHub's own reading of `Closes #N`, so `#54` never matches `#544`):

```bash
gh pr list --state open --limit 100 --json number,headRefName,closingIssuesReferences --jq '.[] | select(any(.closingIssuesReferences[]; .number == <N>)) | {number, headRefName}'
```

A `follow-<N>` worktree with nothing ahead is stale: undo its Workflow → Worktree setup,
`git worktree remove` (no `--force`), `git branch -D`, count it `todo`. If git refuses over
uncommitted changes, it is `resume-worktree`. A dry run removes nothing (`todo (stale worktree?)`).

### 0.5 Main and the session

- Workflow → Merge is a queue: run Workflow → Main health once. Red → the run still goes ahead (PRs
  reach merge-ready and park at `/flow:finish-prs` gate 5); say so in 0.6.
- Workflow → Worktree setup may depend on a variable not being exported in this session (it says
  so). Check it once; if the session breaks the isolation, stop and tell the user.

### 0.6 Waves

Kahn's algorithm over the non-`done` leaves; a cycle is an error (print it, stop). Print:

```
Wave 1: #538 → Wave 2: #540, #543 → Wave 3: #541
```

then `#<N> <title> — <status>` per leaf in wave order (`done` last), then `main: green` or
`main: red since <sha> (#N) — PRs will park merge-ready` when it applies, then
`Agents: <n> at once; <the load check's line>` (Phase 1; a dry run runs it too).
**`--dry-run` stops here** (no fetch, worktree, task or agent). Otherwise one task per leaf.

## Phase 1: Run a wave

**A pool**: at most n of this run's agents alive (Workflow → Agents → `at most <n> at once`;
missing: 3). Fill free slots with the wave's runnable issues in order: a load check before each
spawn, prepare (1.1), spawn (1.2); those that fit go in one message. Each completion notification
frees a slot: book it (1.3), fill it. The next wave starts once this one is booked. An issue not
spawned yet has no worktree: a resumed run counts it `todo` (0.4).

**Load check**: `ruby ${CLAUDE_PLUGIN_ROOT}/skills/follow-through/load.rb`, plus `--max <x>` when
Workflow → Agents sets `max load <x>× cores` (default 1.5). Exit 0 (`ok`, `unknown`) → spawn.
Exit 3 (`busy`: load more than that many times the cores) → spawn nothing; wait for this run's next
notification; none alive → re-check every minute in a foreground loop under `timeout 540` that
ends when the check exits 0 (Bash timeout 600000), re-run up to 30 min, then spawn **one** anyway (it holds a slot; the next spawn checks afresh) and report the
busy machine (Phase 2).

### 1.1 Worktree

- `todo`: `git fetch origin main` and
  `git worktree add .claude/worktrees/follow-<N> -b issue-<N>-<slug> origin/main`
  (a leftover `issue-<N>-*` branch with nothing ahead and no worktree: `git branch -D` it first)
  (slug: title, lowercase kebab-case, ≤ 5 words, ASCII).
- `resume-worktree`: use it as it is; a branch without one gets
  `git worktree add .claude/worktrees/follow-<N> <branch>`.
- `resume-pr`: the existing `follow-<N>` if it is on the PR's branch. Checked out anywhere else (the
  user's tree, a sibling checkout) → book `needs-user` ("branch checked out at <path>"), spawn
  nothing. Else `git fetch origin <headRefName>` and add the worktree on it.

Then run **Workflow → Worktree setup** in every new worktree with `<N>` = the issue number (copies of
gitignored files, per-worktree databases or ports, dependency installs). Without that line, a bare
worktree is enough.

### 1.2 Spawn

`Agent`, `subagent_type: "general-purpose"`, **`model: "opus"`** (spawned agents otherwise run on the
default subagent model), `description: "follow-through #<N>"`, this brief filled in:

```
You are running issue #<N> of a /flow:follow-through run, unattended. Nobody will answer a question.

Issue: #<N> — <title>
Main working directory: <absolute repo root>
Your worktree: <absolute repo root>/.claude/worktrees/follow-<N> (branch <branch>)
Start: <lfg | lfg-resume | finish-prs #<PR>>

Work only inside your worktree: cd into it in every Bash call, or use absolute paths. Never touch the
main working directory, main, or another issue's worktree. AGENTS.md → Workflow → Worktree setup says
what isolates your worktree (databases, ports, a dev server); respect it.

1. Start = lfg: run /flow:lfg <N> (Skill tool). The branch is prepared; its Phase 0 keeps it.
   Start = lfg-resume: the branch has this issue's work (git log origin/main..HEAD, git status). Run
   /flow:lfg <N> but SKIP Phase 0; rebuild the criteria and plan in Phases 1-3, continue Phase 4 where
   the work stops; never redo committed work.
   Start = finish-prs: go to step 3.
2. As soon as the PR is open, post /flow:lfg's Phase 9 close-out on it (gh pr comment <PR>
   --body-file <file>): nobody reads this session before the merge.
3. Phase 8 is /flow:finish-prs <PR> automerge; you have no ScheduleWakeup. Every wait ends on its
   own: foreground, Bash timeout at most 600000, re-run; never a background polling loop. It
   exits on every terminal state (merged, closed, the check or review done either way), never on
   one exact value that can become unreachable (a head SHA). A poll is a loop under `timeout`
   (a bare `sleep` of a minute or more is refused); anything backgrounded runs under `timeout`
   (≤ 2 h).
4. A library limitation goes through /flow:plan upstream <owner/repo> <limitation> --unattended:
   it files the upstream issue and the adoption issue and returns their numbers. Keep the workaround,
   link both in the PR, and add them to your final JSON. Do not implement the library fix yourself.
5. Never ask a question or offer a choice. A finding, failing check, queue eviction or validator note
   is work: fix it now, in this PR, whatever its severity. Park only for a blocker outside the
   repository (an outage, missing credentials, a GitHub permission, a red main under a merge queue),
   or where AGENTS.md says a human must decide: comment on the PR (on issue #<N> if no PR exists) with
   the blocker and what removes it, then stop. Agent tool unavailable → park
   "validator-unavailable"; never skip flow:fable-validator. If a skill is not found, read
   ${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md and follow it.
6. Your final message is exactly one JSON object:
   {"issue": <N>, "pr": <number|null>, "url": "<url|null>", "state": "merged"|"needs-user",
    "merge_sha": "<sha|null>", "reason": "<one line; empty when merged>",
    "upstream": [{"repo": "<owner/repo>", "issue": <n>, "adoption": <n>}]}
```

Wait for completion notifications; never poll an agent or GitHub.

### 1.3 Book each result

Verify the claim: `gh pr view <pr> --json state,mergeCommit --jq '{state, sha: .mergeCommit.oid}'`.
Not the JSON, or a `merged` the PR does not confirm → `needs-user` with that reason.

- **merged**: undo Workflow → Worktree setup, `git worktree remove .claude/worktrees/follow-<N>`
  (`--force` only over leftover untracked files: the work is merged), `git branch -D <branch>`.
  Comment on each umbrella: `#<N> merged in #<pr> (<short sha>)`. An umbrella with no open child
  left (`gh api 'repos/<its owner/repo>/issues/<umbrella>/sub_issues' --jq '[.[] | select(.state ==
  "open")] | length'` prints 0, and no open `- [ ] #N` item) closes now, named in the arguments or
  not: `gh issue close <umbrella> -R <its owner/repo> --comment "<#N → #pr per child>"`, with the
  repository 0.2 resolved for it. Task completed.
- **needs-user**: leave worktree and PR; task gets the reason. Every issue depending on it, directly
  or transitively, is `blocked by parked #<N>` and never starts.
- **upstream** entries: Phase 1.4.

Then fill the freed slot (Phase 1), until nothing is runnable.

### 1.4 Upstream fixes

For each `{repo, issue, adoption}` an agent reported (a `zoolutions/*` library): the library's local
checkout is `<parent of this repo's root>/<repo name>` (clone with `gh repo clone <repo> <path>` if
missing). Spawn one `opus` agent there, `description: "upstream <repo>#<issue>"`, brief: work only in
that checkout — `cd <absolute library path>` in every Bash call (the shell's directory resets
between calls, and `{owner}/{repo}` resolves from it), pass `-R <owner/repo>` to every `gh` call, and
read `<absolute library path>/AGENTS.md`, never this repository's; run its
`/flow:follow-through <issue>` (it has the flow plugin like every repository);
once merged, cut a patch release with the library's Workflow → Release (`/ruby-gem:release patch` for
a gem); final message one JSON object `{"repo", "issue", "pr", "state": "released"|"needs-user",
"version", "reason"}`. Never spawn two for the same issue.

When it reports `released` (verify: the version tag exists, `gh release view v<version> -R <repo>` or
the registry), the **adoption issue** joins this run as a `todo` leaf in the next wave (bump the
dependency to `<version>`, remove the workaround, note it in the PR). `needs-user` → the adoption
issue stays open and is listed in the report.

## Phase 2: Close out

1. Close every umbrella of the run whose children (not only this run's) are all closed, if 1.3 has
   not: `gh issue close <umbrella> --comment "<#N → #pr per child>"`. A child still open is
   reported, never closed by hand.
2. One table. Effort is each PR's estimate → actual, from the data comment `/flow:finish-prs` left in
   its body: `gh pr view <pr> --json body --jq '.body | capture("<!-- flow:effort (?<j>\\{.*?\\}) -->")?.j | fromjson | "\(.estimate.size // "—") → \(.actual.size // "—"), \(.actual.active_hours | if . then "\(.) h" else "not measured" end)"'`
   (empty: `—`). The orchestrator's own turns are in no PR's numbers.

   | Issue | PR | Result | Effort |
   |---|---|---|---|
   | #538 | #600 | merged ✅ `abc1234` | M → M, 3.1 h |
   | #540 | #601 | parked ⚠️ <reason> | S → M, 2.4 h |
   | #541 | — | blocked ⛔ by #540 | — |
   | lib#77 | lib#80 | released ✅ v1.4.2 → adoption #612 merged | S → S, 1.2 h |

3. A spawn the busy machine delayed 30 min (Phase 1): its load line.
4. Per parked issue: what the user must do (from its PR comment), then the resume command:
   `/flow:follow-through <same arguments>` — Phase 0.4 picks up every PR and worktree where it was left.

## Never

Write application code or resolve a conflict yourself; merge a PR yourself or bypass a merge queue;
change `/flow:lfg`'s phases; close a child issue by hand; edit an umbrella's body (comments only); ask
the user mid-run; let one parked issue stop issues that do not depend on it.
