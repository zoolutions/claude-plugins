---
name: sync
description: Keep the repository's lode true to the code. Use after the user accepts a change ("ship it", "looks good", "this is final"), after any change to behaviour or structure, when asked to "audit the lode", for a session handover, or after a merge that touched lode/. Updates the lode to describe the system as it now is; never leaves changelog prose.
argument-hint: "[audit | handover]"
allowed-tools: Bash(git *), Bash(ls *), Bash(cat *), Bash(find *), Bash(mkdir *), Bash(grep *), Bash(wc *), Read, Grep, Glob, Edit, Write
---

# /lode:sync

The lode is the assistant's memory of this repository. Its value is measured one way: after a session, does it describe the system as implemented? This skill is how it stays that way. The method is Lode Coding by fjzeit, adapted for a plugin that many repositories share.

## Principles that do not bend

- The human owns the code and makes the final call. The lode is for the assistant; summarise it when asked, do not paste it back.
- The lode states current behaviour, its rationale, its invariants and its lessons. Not "on Tuesday we added retries" but "the client retries 5xx and transport errors three times with growing waits; 4xx fails at once".
- When the lode and the code disagree, the code is the truth. Fix the lode and tell the user what was wrong.
- One topic per file, under 250 lines, kebab-case names, relative links between files, Mermaid for diagrams.
- `lode/tmp/` is git-ignored scratch. Session notes, handovers and gate output live there. Nothing in `tmp/` is memory.
- `lode/review/` is written by `/lode:learn` and `/lode:seed`; this skill may correct an entry the code contradicts, but new rules come from findings, not from here.

## Structure to maintain

```
lode/
  summary.md  terminology.md  practices.md  lode-map.md
  review/<area>.md      accepted review findings as rules (the gate reads these)
  plans/                roadmaps, or a link to where they live
  tmp/                  git-ignored
  <area>/summary.md + focused topic files
```

Create a missing part when the code has grown a subsystem the lode does not name. Delete a file only when the subsystem it described is gone from the code.

## Modes

**After a change (default).** Identify which lode files describe the behaviour or structure that changed. Rewrite those passages so they are true now. Add a new topic file when the change introduced a concept with no home. Update `lode-map.md`. Stage `lode/` and commit `docs(lode): <what is now described>` on the current branch, so the memory lands with the code.

**`audit`.** Walk every lode file. For each claim, find the code that makes it true. Fix what drifted. Report a table of claims that were wrong and what the code actually does; any of those that reveal a code bug become a note for the user, not a code edit.

**`handover`.** Write `lode/tmp/handover-<date>.md`: task state, decisions made and why, approaches tried and rejected, blockers, exact next steps, files in flight. Enough that a fresh session seeded with the map and this file continues without loss. Do not commit it.

**After a merge.** Accept the incoming lode changes, then reconcile: a file both sides edited is rewritten from the merged code, not stitched from both texts.

## Session start

The plugin's SessionStart hook prints `lode/summary.md` and `lode/lode-map.md`. Read `lode/terminology.md` and the relevant area summary before exploring code for a task; the map is the index and beats a directory listing. When the lode already answers a question, say so and cite the file.

## Nudges to use naturally

- "Let me capture this design in `lode/<area>/…` before implementing."
- "That's settled; updating the lode so it isn't lost."
- "The lode says X but the code does Y; I'll fix the lode and flag it."
