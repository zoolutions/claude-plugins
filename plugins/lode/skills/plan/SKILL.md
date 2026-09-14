---
name: plan
description: Design a change before building it. Use for anything non-trivial before /lode:lfg or any implementation session — a feature crossing layers, a change to a persisted format, a fix whose shape is not obvious. Read-only, never edits application code; it investigates from the lode, interviews the open decisions, and leaves a durable plan as a GitHub issue or a plan file the executor can implement without this conversation.
argument-hint: "<feature or problem> [--issue | --file] [--tier critical|standard|light [--why \"<reason>\"]]"
allowed-tools: Bash(git *), Bash(gh *), Read, Write, Edit, Glob, Grep, Agent
---

# /lode:plan

Design expensive, execute cheap. The thinking happens once, here, and the implementation happens later in a session that has none of this context. That split only pays if the plan is self-contained: an executor reading it cold must be able to build the change without guessing at a decision this session already made.

Two rules hold for the whole run. **Nothing is edited but the plan** — no application code, no commits, no branches. And **the lode is read before the code**: `lode/lode-map.md` is the index, the area summaries are the briefing, and a `Grep` fired before them is usually aimed at the wrong file.

## 0. The profile

`lode/workflow.md` is the repository's answer to everything this skill needs that is not in the code. Read it first, with `CLAUDE.md` and `.claude/rules/*.md`.

If it is missing, say so in your first message: "This repo has no `lode/workflow.md`; deriving the commands, layers and constraints from `CLAUDE.md` and `.claude/rules/`. Run `/lode:seed workflow` to make them durable." Then derive what you can and mark any fact in the plan that you inferred rather than read. Do not create the profile here.

## 1. Read the lode

In this order, before any search:

1. `lode/lode-map.md` — the index. It names the areas; pick the ones the request touches.
2. `lode/summary.md` and `lode/terminology.md` — the system's invariants and its own words. Use its words in the plan.
3. `lode/<area>/summary.md` and its topic files, for each area picked.
4. `lode/review/<area>.md` — rules the repository has already paid for in review. A design that breaks one of these is a design that will fail the gate.
5. `lode/workflow.md`: **Layers** (who owns which files and the edit rule for each), **Shapes** (what every change must be checked against), **Constraints** (suggestions that are wrong here), **Commands**, **Docs**, **CI**, **Flake sources**, **Conflicts**, **Verification**.

When the lode already answers a question, cite the file rather than re-deriving it from code.

## 2. Output mode

| Argument | Artifact |
|---|---|
| `--issue`, or nothing | a GitHub issue on the `origin` repo (`gh repo view --json nameWithOwner`) |
| `--file` | a markdown plan at the path `lode/plans/README.md` names, falling back to `lode/plans/YYYY-MM-DD-<slug>.md` |

Fall back to `--file` when there is no GitHub remote or `gh auth status` fails.

Dedupe before writing either: `gh issue list --search "<keywords>"` and a look through the plans directory. If something already covers this, extend it and say so instead of creating a second artifact. Never put a secret in the plan, redacted or not.

## 3. Investigate

Delegate the mechanical sweeps, keep the judgment. Launch independent `Agent` explorations in one message; pass a cheap model for file discovery and naming sweeps.

The profile's **Rigor** heading sets how much this plan spends. Classify the files the request will touch (`printf '%s\n' <files> | bash "${CLAUDE_PLUGIN_ROOT}/scripts/rigor.sh" --files`, or `--tier` in `$ARGUMENTS`). At `light`: no subagents unless the sweep is more than a handful of files, at most one interview question in step 4, and the options in step 5 may be one paragraph. Standard and critical get the full method below; a critical path is exactly where the rejected options earn their keep.

- Read the load-bearing files yourself — the ones the decision actually hinges on. Do not design from subagent summaries alone.
- For every file the change will touch, record its **Layers** row: owned here, owned elsewhere and additive-only, generated, or vendored. The edit rule travels into the plan; an executor who does not know a file is generated will edit the artifact instead of its source.
- Read the tests that already cover the area, and the docs page **Docs** maps to the behaviour.
- `git log --oneline -15 -- <files>` for recent related work. The design should extend it, not fight it.

## 4. Surface the unknowns

Investigation says what the codebase does; this says what the *request* left out. Do it before designing — an assumption caught here costs one question, caught in review it costs a rewrite.

**Blindspot pass.** Write down what you are carrying: decisions the request leaves open (names, defaults, the public surface, the upgrade story for state written before this change existed); the entries in **Shapes** the request never mentions; anything with no precedent in the repo, flagged as such.

**Interview.** Ask the user directly, one question per message, ordered by blast radius: the public or persisted surface first, then formats other tools read, then wording. Skip anything `CLAUDE.md`, the rules, the lode or an existing issue already answers. Two to five questions is the range (at most one at `light`); zero is fine when the request is genuinely unambiguous — say so rather than inventing one. Every question offers concrete options and names your recommended default.

Answers become `Settled in interview:` bullets under Decision. The executor may not re-litigate them.

## 5. Design

Develop two or three candidate approaches with real trade-offs — not one plan and two strawmen. Pick one, say why, and record why each other lost; the rejected options are what stops the same debate reopening in review. At `light`, one paragraph naming the chosen approach and the one it beat is enough.

The chosen design must survive the repository's own rules: the invariants in `lode/summary.md` and the area summaries, every rule in `lode/review/`, the edit rules in **Layers**, and **Constraints** — if an approach is something the Constraints table already calls wrong here, it is not a candidate.

Then decide the test strategy from **Commands** and the repo's testing rules: which level covers each behaviour, which existing file the cases belong in, and what **Flake sources** lists — a live or timing-dependent test where a deterministic one would do is a defect the plan can prevent for free.

## 6. Write the plan

```markdown
# <Title>

## Problem
What is wrong or missing, who it affects, and what done looks like. No reference to "as discussed".

## Context (read these first)
`path/to/file` — why it matters, and its edit rule from Layers (owned here / additive only / generated / vendored).

## Options considered
- **A — <name>** (chosen): <what it does>. Chosen because <reason>.
- **B — <name>**: rejected because <reason>.
- **C — <name>**: rejected because <reason>.

## Decision
Binding. The chosen approach in a paragraph, with the invariant or lode rule that forced it.
`Settled in interview:` one bullet per answer the user gave.

## Changes, file by file
| File | Change | Edit rule |
|---|---|---|
| `path` | <what> | <from Layers> |

## Shapes to handle
Every entry from Shapes this change touches, plus any new one it introduces, each with the expected behaviour.

## Test plan
Which test file, which level, which case per shape — and the command from Commands that runs it.

## Docs and changelog
The page(s) from Docs this change obliges, and the changelog entry under the heading Docs names. Same PR.

## Risks and rollback
What can break, how it would show, and how to undo it — revert, flag, or migration back.

## Acceptance criteria
- GIVEN <state> WHEN <action> THEN <observable outcome>

## Out of scope
Binding. The adjacent things an eager executor must not do.

## Lode updates
The lode files these decisions should update once implemented (filled in at step 7).

## Execution
Execute with `/lode:lfg <issue number or plan path>`.
```

`/lode:lfg` treats **Decision** and **Out of scope** as binding: an executor that wants to depart from either stops and asks rather than deciding again.

## 7. Ask what the lode should learn

A design conversation is where knowledge is generated; most of it is lost the moment the code lands. Before emitting the artifact, propose the targets from `lode-map.md` and ask the user to correct the list:

- the area summary whose described behaviour this change alters
- `lode/terminology.md`, when the design names a new concept
- a new topic file, when the design introduces something with no home
- `lode/review/<area>.md`, when the interview settled a rule that would otherwise be re-argued
- `lode/workflow.md`, when the change adds a shape, a command or a layer

Write the agreed list under **Lode updates**, one line each saying what that file will have to say. `/lode:sync` does the writing after the code lands; this names the targets so nothing is rediscovered.

## 8. Emit and hand off

For an issue: write the body to a temp file and `gh issue create --title "…" --body-file <tmpfile>`. Never inline the body — shell interpolation mangles code fences.

For a file: `Write` it at the path from step 2 and leave it uncommitted. Committing is the user's call.

Report the link or path, the chosen approach in two or three sentences, the Lode updates list, and the exact execute command. Stop there — planning is the whole job.
