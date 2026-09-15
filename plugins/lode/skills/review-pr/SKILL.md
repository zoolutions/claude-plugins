---
name: review-pr
description: One full pass over an open pull request — resolve merge conflicts with the base, fix red CI, then answer and resolve every unresolved review comment. Run it when a PR needs a full pass, when CI is red, or when there are review comments to process; pass a phase name to run only that phase.
argument-hint: "<PR number or URL> [conflicts|failures|comments] [--tier critical|standard|light [--why \"<reason>\"]]"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent, Skill
---

# /lode:review-pr

A PR is merge-ready when three things are true at once: it merges, it is green, and nothing is left unanswered. This skill makes them true in that order, and the order is the whole point — it is what stops the pass from spending its cycles re-diagnosing work it has already done.

## What it reads first

`CLAUDE.md`, every `.claude/rules/*.md`, `lode/lode-map.md` and the files it indexes (especially `lode/review/*.md`), and `lode/workflow.md`. The workflow profile supplies the repository-specific halves of this skill: **Commands** (how to verify a fix), **Branches and PRs** (base branch, merge policy, attribution), **Layers** (where a fix belongs and what is owned elsewhere), **Shapes** (what every fix must be checked against), **Constraints** (reviewer suggestions that are wrong here), **Docs** (what a change must update), **CI** (workflows, matrix, how to fetch a failure, what green means, known not-this-branch failures), **Flake sources**, **Conflicts** (the per-file resolution table), **Verification**, **Rigor** (how many gates and pushes this pass buys).

No `lode/workflow.md`? Say so in the first line of your report, derive what you can from `CLAUDE.md` and `.claude/rules/`, point the user at `/lode:seed workflow` to write the profile, and carry on. A missing profile degrades the pass; it does not stop it.

## The order, and why

**Conflicts before failures.** CI results only matter for the code that will actually merge. On a stale branch you diagnose failures against a base that no longer exists, and the resolution itself changes code, invalidating the run you just fixed. Resolving first means Phase A reads CI for the post-merge reality, and you spend one extra CI cycle instead of two.

**Failures before comments.** Every commit starts a new run. Fix comments first and the failure log you needed is buried under later runs; a comment fix may accidentally repair or introduce a failure and you cannot tell which. Failures-first keeps CI red or green on a known commit, and the comment fixes layer cleanly on top.

## Phase 0: the PR

Parse the argument flexibly: `PR5`, `pr 5`, `#5`, `5`, a full URL → PR 5. A second word — `conflicts`, `failures` or `comments` — runs that phase alone and then the final report. Empty → auto-detect:

```bash
gh pr list --author=@me --head="$(git branch --show-current)" --state=open --json number,title
gh pr view <PR> --json title,state,url,mergeable,mergeStateStatus,baseRefName,headRefName
```

Exactly one open PR → use it; none or several → ask. `state: MERGED` → report and stop. If `gh` resolves to a different repository than the one you are in (a fork parent), fix the default first (`gh repo set-default <owner>/<repo>`).

Note `baseRefName`. A **stacked PR** — its base is another feature branch, not the default branch — merges *its own base* in Phase A0, never the default branch. When its base merges and GitHub retargets the PR, run Phase A0 again.

---

## Phase A0: merge conflicts

| `mergeable` | Action |
|---|---|
| `MERGEABLE` | Skip to Phase A. |
| `UNKNOWN` | GitHub is recomputing and can stay this way for minutes. Don't poll — check locally against the PR's actual head, not `HEAD`, which may be another branch: `git fetch origin <base>` and `git fetch origin pull/<PR>/head`, confirm both refs resolve (`git rev-parse --verify origin/<base>^{commit}`, `git rev-parse --verify FETCH_HEAD^{commit}` — a bad ref also exits 1 from merge-tree, so the exit code alone proves nothing), then `git merge-tree --write-tree --name-only origin/<base> FETCH_HEAD`. Clean → Phase A. Exit 1 with conflict output → resolve below; the file list is your work list. |
| `CONFLICTING` | Resolve below. |

### Resolution

1. `gh pr checkout <PR>` with a clean tree (`git status --porcelain`). Dirty → stop and ask; stash nothing.
2. `git fetch origin <base>` then **`git merge origin/<base>`** — merge, never rebase. The branch is published; a rebase needs a force-push, which **Branches and PRs** forbids.
3. Resolve every conflicted file **semantically**: read both sides and produce the version that keeps both intents. Never blanket `--ours`/`--theirs` a source file. The per-file table is **Conflicts** in `lode/workflow.md` — lockfiles regenerated rather than hand-merged, changelogs unioned under one heading, registries kept append-only in base order, fixtures forked rather than merged. A file the table does not name is resolved by reading both sides.
4. Verify **before** pushing the merge, scoped to what the conflict touched: the fast-loop command from **Commands** for each touched file, then the full suite; the docs or lint command if the conflict reached those paths.
5. Commit the merge (git's standard message, plus a body line naming any non-obvious choice), then run `/lode:gate`, then push. The gate needs a clean tree and stamps the tree at `HEAD`, so the commit comes first; on a branch its ledger has never seen it reviews the whole `<base>...HEAD`; afterwards its delta for a merge commit is what the merge itself did (its combined diff) plus the files both sides changed, against each parent — the resolution, a one-sided `--ours`/`--theirs` shown as the revert it is, and each side's own hunk in a file both touched; files only the base changed do not appear. A merge commit never needs force.

A resolution you cannot make with confidence — both sides rewrote the same logic and the right combination is not decidable from the code — is a **question, not a guess**. Stop and ask. A guessed resolution that compiles is worse than a question.

A merge commit already on the local branch and not yet pushed — `/lode:finish-prs` leaves a clean merge-forward this way — is this phase's work item too: gate it and push. In a worktree the gate has already run in, a clean merge's delta is empty and the pass is immediate; in a fresh worktree — finish-prs's — this is the one full-diff round the branch gets, and every later phase reviews only its own delta.

**Exit:** `MERGEABLE` (or a clean local `merge-tree`), the merge commit pushed if one was needed. CI re-running is expected; Phase A reads the fresh run.

---

## Phase A: CI failures

1. **List the checks.** `gh pr checks <PR>`. Read the shape before reading any log — **CI** in the profile names the workflows and the matrix, and the pattern of red cells is the first diagnosis: every cell on the same test is a deterministic regression; one runtime version is a compatibility floor; one dimension of the matrix points at whatever that dimension varies; one lone cell with a transport error is the flake question below.
2. **Fetch the logs** with the command **CI** gives (usually `gh run view <RUN_ID> --job=<JOB_ID> --log-failed`; fall back to the full log piped through `grep -n -B5 -A30` when `--log-failed` is too thin). Run and job IDs come out of the check URLs. Extract per failure: test name and file, error class and message, any seed, the cell.
3. **Diagnose the root cause.** Read the failing code and test before changing anything. A failure that is already red on the base branch is not yours: confirm it on the base, note it, leave it.
4. **Is it a flake?** Only when the failure sits in one of the repository's own **Flake sources**, the error is of that source's shape, and the same test passed in the other cells on the same commit. Then hand it to `/lode:debug-flaky` — never a `retry`, a `sleep`, a `skip` or a loosened assertion. Suppression converts a known bug into an unknown one.
5. **Fix locally**, at the root cause, in the layer **Layers** assigns it, honouring the edit rule for anything owned elsewhere. Check the fix against **Shapes** before believing it.
6. **Verify** with **Commands** — the fast loop for the failing file, then the full suite, and in the failing cell's configuration when the failure is cell-specific (**CI** says how a cell differs from local).
7. **Commit, gate, push.** One commit for the whole phase first — `fix(ci): …` with a bullet per failure, cause → fix — then `/lode:gate` on it (it requires a clean tree and stamps the tree at `HEAD`), then push. Each push runs the whole matrix; do not spend two.
8. `gh pr checks <PR>` once to report what is re-running. Do not poll in a loop — no `for` or `while` with a `sleep` around `gh`, foreground or background. A check that is not final is reported as pending.

**Exit:** one of — all checks green on the latest commit; all pending with nothing failed in the last completed run on it; or a persistent failure **not caused by this branch** (one the base reproduces, an outage, a known not-this-branch failure from **CI**), reported explicitly and carried into Phase B as a caveat. Failures that trace to this branch and persist → do **not** proceed. Report what fails, what was tried, and ask.

---

## Phase B: review comments

Fetch every thread and its resolution state:

```bash
gh api "repos/<owner>/<repo>/pulls/<PR>/comments" --paginate
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!) {
    repository(owner:$owner,name:$repo) { pullRequest(number:$pr) {
      reviewThreads(first:100) { nodes { id isResolved path line
        comments(first:20) { nodes { id databaseId body author { login } createdAt } } } } } }
  }' -f owner=<owner> -f repo=<repo> -F pr=<PR>
```

Keep the unresolved threads; skip resolved ones and PR-description comments. **Bot reviewers — cubic, CodeRabbit, dependabot — get exactly the treatment a human gets: evaluated, neither auto-accepted nor auto-ignored.** No unresolved threads → report and stop.

**Snapshot the pass.** Write down the unresolved thread ids and the newest comment's `createdAt` now. This pass replies to and resolves those threads and no others. A thread that appears after the snapshot — a bot re-reviewing the push this phase is about to make — goes under *Outstanding* in Phase C, unprocessed; the next pass starts from it. Processing it here means another gate, another push and another bot review, without end.

**Before categorising any comment**, every time:

1. Read the actual file and line, at the branch's current state.
2. Check the suggestion is right for *this* codebase — **Shapes** names the inputs, states and environments it has to survive.
3. Check what else shares the code the comment points at; a fix in one path usually has siblings.
4. Check `CLAUDE.md`, `.claude/rules/*.md` and `lode/review/*.md` — the repository's own conventions outrank a reviewer's preference, and a rule already written down may settle the thread outright.

Then categorise:

| Category | Action |
|---|---|
| Valid fix | Implement |
| Valid test gap | Add the test, in the repo's framework and at the level **Layers** puts it |
| Valid docs gap | Update what **Docs** says a change of this kind updates, changelog included |
| Style, in a file this repo owns | Fix |
| Style, in a file owned elsewhere (upstream, generated, vendored) | Push back: the edit rule in **Layers** governs, not taste |
| Conflicts with a constraint | Push back with the constraint from **Constraints**, named |
| Over-engineering / YAGNI | Push back |
| Unclear | Ask; do **not** implement |

A half-right finding is the common case: the reported failure is not the one that happens, but there is one. Before accepting, **confirm the actual failing input** and fix that; before rejecting, confirm that no input fails. Say which one you did in the reply.

Implement the accepted fixes, verify with **Commands** — plus the manual check in **Verification** when the fix changes something a user sees — make **one commit for the phase** so CI runs once, then run `/lode:gate` on that commit, then push. The gate requires a clean tree, so the commit comes first. Then reply to every thread:

```bash
gh api "repos/<owner>/<repo>/pulls/<PR>/comments/<COMMENT_ID>/replies" --method POST \
  -f 'body=Fixed in <SHA>. <What changed.>'      # or: the technical reason it was not
gh api graphql -f query='mutation($t:ID!){ resolveReviewThread(input:{threadId:$t}){ thread { isResolved } } }' \
  -f t=<THREAD_NODE_ID>
```

General (non-inline) comments get `gh pr comment <PR> --body "…"`. Re-run the threads query at the end and confirm every thread in the snapshot is resolved; anything newer is listed under Outstanding, not processed.

**Reply style:** no performative agreement, no gratitude. The fix or the reason, nothing more. Every accepted fix cites the short SHA. Every push-back names the file, the rule or the constraint and what would break — never a principle. Several comments asking for the same thing get one fix, cited in each reply. A fresh round of comments after your push is reported, not looped on.

**Learn from it.** Invoke `/lode:learn <PR>` before you finish: each accepted finding becomes a rule in `lode/review/`, and each rejected one becomes a **"Not a bug"** entry with its reason — that is what stops the same reviewer raising it next month.

**Exit:** every unresolved thread replied to and resolved (or the user explicitly agreed to leave one open), and the branch pushed with all accepted fixes.

---

## Phase C: report

Re-check mergeability (`gh pr view <PR> --json mergeable`, or the local `merge-tree` check if `UNKNOWN`) — the base can move under a long pass. A new conflict loops back to Phase A0.

```
## Phase A0 — conflicts
clean | <files>, how each was resolved, merge commit <sha>
## Phase A — CI
<failure> → <cause> → <fix> in <sha>; carried caveat: <not-this-branch failure>
## Phase B — comments
accepted: <n> (<shas>) · pushed back: <n> (<one-line reasons>) · unresolved: 0
## End state
mergeability + CI status on the latest commit, per workflow
## Spent
<one block per gate this pass ran: the output of gate-ledger.sh show — rounds, delta lines per round, agents by name and model>
## Outstanding
<CI pending after the comment fixes, a follow-up owed on the base, a thread left open, review threads that arrived after the Phase B snapshot>
```

## Rules that hold across the whole pass

- **Do not interleave the phases.** A new CI failure during Phase B loops back to Phase A; a new conflict mid-pass loops back to Phase A0. Those are the only reverse moves.
- **Never rebase a published branch.** Merge the base forward, always.
- **Batch fixes into one commit per phase.** Every push buys a full CI run; buy one per phase.
- **Every accepted fix goes through `/lode:gate` before the push** — the hook requires it, and the gate is a cheaper reviewer than the one who is waiting. Each phase's gate reviews only that phase's commits (the ledger's delta): one full-diff round on a branch the gate has never seen, small rounds after.
- **Never pass `model` to a gate agent.** The agent definitions declare their models; the Agent hook refuses an override.
- **No polling loops**, at any phase. Report what is pending and stop.
- **At `light`, one gate and one push per pass.** Resolve the tier first (`bash "${CLAUDE_PLUGIN_ROOT}/scripts/rigor.sh" origin/<base>` on the PR's checkout, or `--tier` in `$ARGUMENTS`). When it is `light`: each phase still makes its one commit, but does not gate or push; Phase A0's local verification of a resolution is all the checking a merge gets, and Phase A reads the last completed CI run rather than a fresh one; after the last phase run, one `/lode:gate --tier light` (with the `--why` reason when the tier was lowered by hand, so it reaches the gate report and the PR), one push, and the CI status in Phase C is read from that single run. The per-phase CI cycle is what standard and critical pay for a clean failure diagnosis; a light repo has said that diagnosis is cheap to redo.
- **Clean, green, nothing unresolved** → report "PR is clean" and stop.
