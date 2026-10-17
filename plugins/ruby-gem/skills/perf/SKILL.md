---
name: perf
description: Benchmark the current branch against main on the same machine, main checked out in a worktree, and report an honest before/after. Use when a change touches a hot path, or before any speed or allocation claim goes into a PR.
argument-hint: "optional: one bench or hot path (e.g. client_bench, render); empty = the full suite"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep
model: sonnet
---

# Perf: $ARGUMENTS

`main` below is the default branch: Workflow → Base when set, else `main`.

Measure, don't guess. **Read the repository first:** `AGENTS.md` → `## Workflow` → **Bench** names the
bench command (full and one), the doc that lists the hot paths, and what CI holds (e.g. allocations
against a committed baseline). `none` → there is no suite: use a scratch script (step 3).

**The rule.** A delta needs a baseline from the same machine, the same script and the same Ruby, taken
now. Never compare with a number from another machine, another day or a CI log. A change that already
landed gets its baseline rebuilt from `main` in a worktree.

## 1. Is there anything to measure?

Read `git diff origin/main...HEAD` against the hot paths. A change confined to code dominated by
network, I/O or a one-off command (setup, a CLI, an installer) needs no number: say so and stop.

## 2. `main` in a worktree (before)

Never switch the tree you are working in.

```bash
git fetch -q origin main
git worktree add --detach .claude/worktrees/perf-main origin/main
```

Then run Workflow → Worktree setup in it, and `bundle install`. **Same harness in both trees:** when
`main` predates the bench (the script, the rake task, a Gemfile entry), copy the branch's harness files
into the worktree; when the branch's bench calls a method `main` lacks, write a baseline-safe variant
and run that one in both trees. Save the output outside the repository (`mktemp -d`).

## 3. The branch (after), then clean up

Same command, same arguments (`$ARGUMENTS` names one bench → only that one, in both trees). Noisy
results: three runs per tree, report the middle one. Then
`git worktree remove --force .claude/worktrees/perf-main`.

**No suite.** A scratch script, never committed, run in both trees (`bin/rails runner` for an engine's
dummy app): per operation, wall time over N iterations and allocations from the
`GC.stat(:total_allocated_objects)` delta around the loop; retained objects separately: `GC.start`
before and after N operations, then compare `ObjectSpace.count_objects` (or `memory_profiler`'s
retained report) — allocation counts never show retention. Measure a cached and a cold path
separately when there is a cache.

## 4. Report honestly

- Time (i/s or µs/call with its ±) **and** allocations (objects/call, retained). Retention that keeps growing
  across repeated runs after warm-up, with no cache or memo to explain it, is a leak: name it. A
  bounded cache or a memoised value retains by design.
- A delta inside the ± (or inside the spread of the three runs) is "within noise".
- Say what level the number describes: one method, or a whole render, request or job. A 2× faster
  method is not a 2× faster system when I/O dominates it.
- Cached against cold, when there is a cache: a change that speeds up cold and slows down cached moves
  the cost to production.
- No baseline → "measured after only".

## 5. Keep it

- The before/after table in the PR body.
- A bench exists for the hot path changed; add one when missing, in the suite's layout.
- What CI holds (Workflow → Bench) passes; its baseline is re-recorded only for an intended change, with
  the reason in the commit.
- The hot-path doc's representative numbers updated when they moved; a changelog bullet when a user
  would notice.
