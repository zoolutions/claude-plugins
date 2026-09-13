---
name: finish-prs
description: Drive a set of open PRs to merge-ready, one at a time, in a given order. Use when several open PRs need to land in order, or a stack of PRs based on each other's branches. Reads lode/workflow.md → Conflicts to auto-resolve the recurring mechanical conflicts (a changelog union, a lockfile regenerate), runs /lode:review-pr on each, then waits for the user to merge before syncing the rest and advancing. Handles stacked PRs, including GitHub's base retargeting when the lower PR merges.
argument-hint: "<PR numbers in order, e.g. 12 14 15>"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
---

# /lode:finish-prs

You are driving a set of open pull requests to **merge-ready**, one at a time, in a defined order, minimizing the sync/CI churn that stacked or parallel PRs create. This command does not merge anything unless told to; it makes each PR ready, waits for a human, and advances.

## 0. Read the profile

Read `lode/workflow.md`, and `lode/lode-map.md` for the areas the queued PRs touch. If the profile is missing, say so once, fall back to `CLAUDE.md` and `.claude/rules/*.md` for the same facts, and tell the user that `/lode:seed workflow` should grow a `workflow.md` profile (template at `${CLAUDE_PLUGIN_ROOT}/templates/workflow.md`) so this and the other shared skills stop re-deriving it every run.

Pull from the profile before touching a PR:

- **Branches and PRs** — the default branch to sync against, the merge policy on land (squash/merge), commit and attribution conventions.
- **Conflicts** — the per-file table this command auto-resolves against. This is the whole trick: every repository has one or two files that conflict on nearly every PR (a changelog appending under the same heading, a lockfile that pins a version another file bumps, an append-only registry). The repository names them here instead of this skill hard-coding them.
- **Docs** → *Files that pin a version and drift after a release* — each path and the command that regenerates it; drives the no-conflict drift check in 2b.
- **CI** → *Shared or rate-limited services the checks hit*, plus the matrix and what "green" means; the shared-services line is what makes the queue serial below.
- **Flake sources** — known non-defect red checks, so a genuinely intermittent failure isn't "fixed" by rewriting a test.

## Phase 0: Parse the list and order

`$ARGUMENTS` may be:

- An ordered list: `12 14 15` (also `#12`, `PR12`).
- `automerge` anywhere → `gh pr merge --auto --squash` on each PR once merge-ready; strip it before parsing numbers.
- Empty → discover: `gh pr list --author=@me --state=open --limit 100 --json number,title,headRefName,baseRefName,createdAt`. Order **base-first, then oldest-first**: a PR whose branch is another open PR's base goes before it; otherwise `createdAt` ascending. Show the order and proceed.

**Stacked PRs.** A `baseRefName` that is not the default branch means the PR is stacked on another open PR; it must come after its base in the order. When the base merges, GitHub retargets the stacked PR to the default branch automatically — verify with `gh pr view <PR> --json baseRefName` before syncing it, and `gh pr edit <PR> --base <default>` if it didn't.

Track the queue as a simple ordered table you keep in your response, one row per PR, updated as you go — no external task tool is required. State the plan in one line: `Finishing N PRs: #a → #b → #c. Mode: <pause-for-merge | automerge>.`

## Phase 1: A working tree per PR

Never operate on the branch checked out in the main working directory. Per PR, in order of preference:

1. An existing worktree on that branch (`git worktree list`).
2. `git fetch origin <branch> && git worktree add "$(mktemp -d)/finish-<PR>" <branch>` — a temp directory, never a path inside the repository, where it would show up in a diff or a build.

Each worktree needs its own dependency install before tests run (whatever **Commands** in the profile names). Whether two worktrees may run the suite at once is the *safe to run in two worktrees at once* note on the full-suite row of **Commands**; if it says no, run them one at a time instead of discovering the shared database, port or fixture directory mid-queue.

## Phase 2: Per-PR loop

### 2a. Sync onto the base — merge, never rebase

```bash
cd <worktree>
git fetch origin <default> --quiet
git merge origin/<default>
```

Every branch here is published (it has an open PR), so it is never rebased — only merged forward. A merge commit is fine; PRs squash or merge on land per **Branches and PRs**.

If the merge conflicts, resolve **only** the files the profile's **Conflicts** table names, using that table's rule for each:

- A same-anchor union (most changelogs): both sides inserted under the same heading, so strip markers and keep both blocks —

  ```bash
  perl -0pi -e 's/^<<<<<<< [^\n]*\n//mg; s/^\|\|\|\|\|\|\| [^\n]*\n(?:(?!^=======$).)*?^=======\n//mgs; s/^=======\n//mg; s/^>>>>>>> [^\n]*\n//mg;' <file>
  ```

  Run it, then **read the result**: no markers left (`grep -n '^<<<<<<<\|^=======\|^>>>>>>>\|^|||||||' <file>`), this PR's entry present once, nothing from the base dropped, no duplicated heading. The perl is a fast path, not a substitute for reading; a shape other than "both sides at the same anchor" is resolved by hand.
- A "never hand-merge, regenerate" file (most lockfiles): take the base's side and regenerate — `git checkout origin/<default> -- <file>` then whatever **Commands** names to regenerate it. Confirm the resulting diff is only the regeneration, not a version bump you didn't expect.
- An append-only file (a registry, a route list): keep both sides' entries, base's order first.
- A "add a second fixture" file: don't merge two shapes into one; add the new fixture alongside.

**Anything not in the table** — stop (`git merge --abort`), report the file(s), and ask. Don't guess a semantic merge in an owned-layer file; that's what `/lode:review-pr` and a human are for.

`git add` the resolved files, `git commit` (the default merge message is fine), repeat if another conflict follows.

### 2b. Check drift even without a conflict

A pin-style file from **Conflicts** can drift out of sync with the base without ever conflicting (a release bumped the version; this branch is older). If this PR touches a path under **Docs** → *Files that pin a version and drift after a release*, compare the pin against the current version and regenerate it with the command named there if they differ, committing on this branch with a conventional message that says why (the frozen/pinned install fails otherwise, not "update lockfile").

### 2c. Gate, then push

The resolution in 2a is committed code nobody has reviewed. Run `/lode:gate` on the committed merge before any push — the push hook denies a push whose tree has no gate pass, and a gate fix is another commit, so gate last and push after.

```bash
git push origin <branch>
```

A merge commit needs no force. If a force is ever truly unavoidable, `--force-with-lease`, never bare `--force` — and only after confirming nobody else pushed to the branch since your fetch.

### 2d. Full review pass

Invoke `/lode:review-pr <PR>` (Skill tool); don't re-implement its conflict/CI/comment logic. Wait for it. A persistent failure it can't fix, or a thread needing a human decision, marks this PR `needs-user` in your queue table — continue to the next PR and return to this one in the final report. One stuck PR must not block the rest.

Before invoking it for the next PR, make sure this PR's checks have actually finished. Never run two PRs through checks at once when **CI** → *Shared or rate-limited services the checks hit* names one — that's the burst a same-endpoint guard exists to prevent. Process the queue strictly serially.

### 2e. Verify merge-ready

```bash
gh pr view <PR> --json mergeable,mergeStateStatus,reviewDecision,baseRefName --jq '{mergeable,mergeStateStatus,reviewDecision,baseRefName}'
gh pr checks <PR>
```

Merge-ready: `mergeable=MERGEABLE`, no failing checks (per **CI**'s definition of green — the whole matrix or the named required checks), `reviewDecision` not `CHANGES_REQUESTED`. `BLOCKED` with everything else green usually means "awaiting required approval" — that's the human gate, not a defect. A check failing in a way **Flake sources** already names as non-deterministic gets a `/lode:debug-flaky` referral, not a local "fix."

### 2f. Hand off

- **automerge:** `gh pr merge <PR> --auto --squash`, then Phase 3.
- **default:** report merge-ready with the PR URL and a one-line summary, tell the user it's ready, then wait (Phase 3). Never merge yourself in this mode.

Update the queue table: `completed` (merge-ready) or `needs-user`.

## Phase 3: Wait for the merge, then advance

Each merge is what invalidates the next PR's base, so the loop gates on it.

- **automerge:** poll `gh pr view <PR> --json state --jq .state` at an interval matched to how long **CI** takes to go green — minutes, not seconds; never a busy loop.
- **default:** the user merges and tells you, or you're re-invoked. Re-check `state`. `MERGED` → advance; otherwise report the current queue and stop — don't spin.

On advance: if the next PR was stacked on the one that just merged, confirm GitHub retargeted it to the default branch (`gh pr view --json baseRefName`; `gh pr edit --base <default>` if not), then **always** re-run 2a against the new base before anything else.

An out-of-order merge by the user drops that PR from the list; sync whatever is now next.

Between PRs, restate the queue (same table as Phase 5) so the state is never implicit.

## Phase 4 (optional): fix the drift at its source

If the same **Conflicts**/**Docs** drift recurs across PRs, its root cause is usually one script (a release task) that updates one lockfile but not a sibling one. Mention this once if it recurs; don't change that script unprompted — it's a change to shared tooling, not to a PR in the queue.

## Phase 5: Final report

| PR | Result | Note |
|---|---|---|
| #a | merged / merge-ready / awaiting-merge / needs-user | one line |

Then: what the user does next (merge the ready ones, decide on `needs-user` items), and whether a recurring drift is worth fixing at the source (Phase 4).

## Important notes

- **Never rebase** a published branch; merge the base forward.
- **Never bare `--force`** — `--force-with-lease` only, and only when unavoidable.
- **Never touch the main working directory's checkout** — worktrees only.
- **Never auto-resolve a conflict outside the profile's Conflicts table** — stop and ask.
- **Never merge in default mode** — the user merges; you make ready and wait.
- **Don't re-implement `/lode:review-pr`** — invoke it.
- **One stuck PR doesn't block the queue** — mark `needs-user`, continue, return to it in the final report.
- **Never run two PRs' checks at once** when **CI** → *Shared or rate-limited services the checks hit* names one.
- **Read every auto-resolved conflict** before pushing — the perl fast path is not a substitute for reading the result.
