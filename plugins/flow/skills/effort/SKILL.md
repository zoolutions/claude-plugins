---
name: effort
description: What a pull request cost and how far it strayed from its estimate — time (wall clock, active, before and after the PR opened), tokens per role and model (the session, each agent type, the advisor), validation passes and verdicts, review rounds and threads, commits and the diff — measured from this machine's Claude Code transcripts and GitHub, and written as the PR body's "Effort & cost" section. Also defines the `## Estimate` table that /flow:plan writes and /flow:lfg makes when a plan has none.
argument-hint: "<pr> [--write] [--estimate <file>] | --branch <name> (before the PR exists)"
allowed-tools: Bash(*), Read
---

# /flow:effort — $ARGUMENTS

Every PR body carries an `## Effort & cost` section: what the work cost, against the estimate made
before it began. The numbers come from `effort.rb` beside this file (stdlib only, any Ruby ≥ 2.6),
which reads Claude Code's transcripts on this machine and, for a PR, GitHub through `gh`. It never
guesses: a number it cannot read says "not measured".

## Run it

`ruby <this skill's base directory>/effort.rb <arguments>` from the repository's checkout:

| When | Arguments (`<N>`: `570`, `#570` or `PR570`) |
|---|---|
| Write or refresh a PR's section | `<N> --write` |
| The first write, when the estimate is not on the issue | `<N> --write --estimate <file>`: the plan file `/flow:lfg` ran, or `implementation-notes.md` when it made the estimate itself |
| Look without writing | `<N>`, or `<N> --json` for the data |
| Before the PR exists | `--branch <name> --issue <N>` |
| The work ran from a session whose checkout is another repository or a throw-away clone, and its commits have no `Claude-Session` trailer | add `--session <id>` (the transcript's file name, or a `session_…` id) and `--since <ISO 8601 time the work began>` |

`--write` re-reads the body, replaces only what lies between `<!-- flow:effort:start -->` and
`<!-- flow:effort:end -->`, or, the first time, inserts the section before
`## Deviations & judgment calls` (else before the session link, else before a bot's generated block,
else at the end). Everything outside the markers stays as it is. A body edit is not a review round:
no re-review, no validator. A workflow the repository runs on `edited` re-runs on it, so the caller
waits for that check before merging.

**Where it went.** When any row's deviation is not `within` (or `—`), the caller (the session that did
the work, never a fresh agent) writes one to three sentences under the end marker, starting
`**Where it went:**`: what made it bigger or smaller, by name (the deviation log's items, what the
validation passes and review rounds were about). Re-read it after each refresh and correct it when the
numbers changed the story; a later session (a separate `/flow:finish-prs`) only appends what it saw,
never rewrites it. A PR without an estimate gets the sentences only when something stands out.

## What it counts

- **Which transcripts.** A session's rows recorded on the branch, in the checkout, its worktrees, or
  another clone whose `origin` is the same.
  An agent whose brief names the branch (a `/flow:follow-through` agent, whose rows record the
  orchestrator's checkout), and every agent a counted row or agent spawned (validators). A session
  named by a commit's `Claude-Session` trailer or `--session` that never ran on the branch, from its
  first row naming the branch; `--session` with `--since` counts that session from then. A session
  that briefed an agent with the branch is an orchestrator, and only its agents count. A merged or
  closed PR stops at its merge.
- **Time.** Wall clock from the first counted entry to the last. Active: per transcript, the gaps
  between entries, leaving out any gap over 10 min and the wait after `ScheduleWakeup`,
  `gh pr checks --watch` or `gh run watch`; then the union over transcripts, so an agent working while
  the session waits counts once. Split at the PR's creation.
- **Tokens.** Per message, from its last line (an agent's transcript streams). Input is fresh + cache
  writes + cache reads. The advisor's tokens are their own iterations: they add to the caller's, never
  repeat them, and are booked to whoever consulted it.
- **Validation passes.** Agents of type `*fable-validator`, each with the verdict its answer opens with.
- **Review rounds.** Distinct heads a reviewer (bot or human) reviewed: the first review, plus one per
  fix it re-reviewed.
- **Not counted.** Work on another machine or in the cloud (its transcripts are elsewhere), and a price
  in money: tokens per model are the cost, prices change.

## The estimate

`/flow:plan` puts this in every plan; `/flow:lfg` makes it when the plan has none, before the first
edit, at the top of `implementation-notes.md`. `effort.rb` reads these row labels; other rows are notes.

```markdown
## Estimate

| | Estimate |
|---|---|
| Size | M — <one line: why> |
| Active time | 2–4 h |
| Validation passes | 1–2 |
| Review rounds | 1–2 |
| Files | 6–10 |
| Would grow if | <the unknown that would blow it up> |
```

- **Size** by active hours: XS < 0.5 · S 0.5–2 · M 2–4 · L 4–8 · XL ≥ 8 (split an XL plan).
- **Ranges:** `2–4 h`, `1-2`, `1 to 3`, `~6`, `45 min`.
- **Active time** is agent time as counted above, not a person's day. **Validation passes:**
  `flow:fable-validator` runs until it passes (a clean change: 1). **Review rounds:** the first review
  counts. **Files:** the final diff, specs and docs included.
- **Calibrate** before estimating, from what recent PRs cost against their estimates:

  ```bash
  gh pr list --state merged --limit 30 --json number,body --jq '.[] | (.body | capture("<!-- flow:effort (?<j>\\{.*?\\}) -->")?.j | fromjson) as $e | "#\(.number) est \($e.estimate // {} | {size, active_hours, validation_passes, review_rounds, files} | tostring) → actual \($e.actual | {size, active_hours, validation_passes, review_rounds, files} | tostring)"'
  ```

  A pattern (validation passes always double, the dashboard always adds a round) moves the estimate.
- The estimate is made once, before the work, and never revised after seeing it: the deviation is the
  measurement. A plan whose scope changes gets a new plan, not a new estimate.

The section's data comment (`<!-- flow:effort {…} -->`) carries the estimate from the first write, so
a refresh compares with the same one. Its source, in order: `--estimate <file>`, the data comment, the
latest comment on the linked issue with an `## Estimate` table, the issue's body (the plan).
