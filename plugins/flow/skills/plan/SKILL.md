---
name: plan
description: Investigate, design and write a self-contained plan — a GitHub issue (default) or docs/plans/ markdown — that /flow:lfg executes without guessing. `upstream <owner/repo> <limitation>` plans a public issue for a library limitation and, for a library we own, carries the fix through to a release and an adoption issue. Read-only on source code.
argument-hint: "issue <feature> | md <feature> | upstream <owner/repo> <limitation> [--unattended] | <feature>"
model: fable
allowed-tools: Bash(*), Read, Grep, Glob, Write, Agent, AskUserQuestion
---

# /flow:plan — design expensive, execute cheap

This runs on the most capable model on purpose: the thinking happens here, execution later on
cheaper ones. That only works if the plan is **self-contained** — an executor with none of this
session must implement it without guessing. Repository facts: `AGENTS.md`, its `## Workflow` section
above all.

| `$ARGUMENTS` starts with | Artifact |
|---|---|
| `issue` or anything else | a GitHub issue |
| `md` / `file` | `docs/plans/YYYY-MM-DD-<slug>.md` (date from `date +%F`), left uncommitted |
| `upstream <owner/repo>` | an issue on that library's tracker — **Upstream mode** replaces Phases 1–5 |

**Hard constraints:** never edit source code, commit or branch (the only file you write is a plan or
an upstream draft under `docs/plans/`); never reproduce a secret; dedupe first
(`gh issue list --search "<keywords>"`) and extend an existing issue instead of duplicating it.

## Phase 1 — Investigate

Delegate mechanical sweeps (Explore agents, `model: haiku`; `model: sonnet` to read and summarise a
subsystem), in parallel. Read the load-bearing files yourself. Read whatever AGENTS.md points at for
past decisions (module notes, per-directory CLAUDE.md). `git log` the area: extend recent work, don't
fight it.

## Phase 2 — Unknowns, then interview

List what the request leaves open (defaults, naming, public API or config surface, rollout and
upgrade), the edge cases the code allows, and anything without precedent here. Then `AskUserQuestion`,
one question at a time, highest blast radius first, 2–5 questions (zero is fine when nothing is open),
each with concrete options and a recommended default. Skip anything the code or AGENTS.md answers.
Record answers as `Settled in interview:` bullets. Under `--unattended` (an orchestrator), take the
recommended default and record it as `Assumed:` instead.

## Phase 3 — Design

Two or three candidate approaches with real tradeoffs; pick one, say why the others lost. Respect
every invariant AGENTS.md states (architecture, interactivity, authorization, i18n, testing strategy).
Name the test strategy. A library limitation in the way gets its own `upstream` plan first.

## Phase 4 — Emit

```markdown
# <Title>

## Problem / Goal
<What is wrong or missing, who it affects, what done looks like.>

## Context (read these first)
<`path` — why it matters. Self-contained: no "as discussed".>

## Decision
<Chosen approach and why; alternatives and why each lost.>
Settled in interview: <bullets the executor must not re-litigate>

## Implementation steps
<Ordered, small; specs before the code they cover; exact files.>

## Verification gates
<Workflow → Verify and the specs for this change, each with its expected outcome.>

## Out of scope
<What an eager executor must NOT do.>

## Execution
`/flow:lfg <issue-number>` (or `/flow:lfg docs/plans/<file>.md`).
```

Issue: `gh issue create --title … --body-file <file>` (or a single-quoted heredoc). Labels per
Workflow → PR contract (typically: a plan label, one type, the areas the Context paths map to).

## Phase 5 — Handoff

The link (or path), the approach in 2–3 sentences, the execute command. Stop: never implement.

---

## Upstream mode — `upstream <owner/repo> <limitation> [--unattended]`

A limitation, bug or missing feature in a library. The issue is **public**: it says nothing about
this repository, its product, its customers or its domain.

1. **Investigate the library, not the app.** Its source at the installed version (`bundle show <gem>`,
   `node_modules/<pkg>`, the vendored copy), its docs, its changelog. Quote the method or file that
   proves the limitation. Check whether a newer release already fixes it (then the plan is a bump).
2. **Dedupe upstream:** `gh issue list -R <owner/repo> --state all --search "<keywords>"`; extend an
   existing issue with a comment instead of opening a second.
3. **Generalise.** Neutral nouns (a list, an item, a `Widget`); a fresh standalone reproduction, never
   app code, paths, class names, routes, copy, links into this repository or screenshots. Keep numbers
   about the library (bytes, ms, request counts), drop where they were measured.
4. **Design the ask** in the library's own conventions: the proposed API, the alternatives and why
   they lose, the files to touch, the tests to add, the compatibility story — enough for an agent with
   only the library checkout. Interview only when the API choice is genuinely open (never under
   `--unattended`: take the most conservative API and say so).
5. **Draft** to `docs/plans/YYYY-MM-DD-upstream-<repo>-<slug>.md`: Summary, Environment (versions),
   Reproduction, Observed / Expected, Proposed API, Implementation notes, Acceptance criteria,
   Workaround today.
6. **Scrub.** Read it as a stranger: if it tells them what this repository builds, rewrite it. Then
   run the scrub Workflow → Upstream names (a denylist matcher); it must print nothing.
7. **Emit.**
   - **A library we own** (Workflow → Upstream lists the owners, e.g. `zoolutions/*`): file it,
     `gh issue create -R <owner/repo> --title … --body-file <draft>`, with labels that exist there
     (`gh label list -R <owner/repo>`), never this repository's.
   - **Anyone else's:** stop at the draft; the operator files it. Unattended: report the draft path.
8. **Carry it through (a library we own).**
   - **Adoption issue, here:** `gh issue create` in this repository: "Adopt <library> fix for
     <owner/repo>#<n>: bump to the release that closes it, remove the workaround at <file:line>", with
     the workaround's location, the upstream link and the check that proves the workaround is gone.
     Label it like any plan issue. Comment the upstream link at the workaround in the code
     (the caller does this in its PR).
   - **The fix, upstream:** `--unattended` (an agent under `/flow:follow-through`): do not start it —
     return `{repo, issue, adoption}`; the orchestrator runs it (its Phase 1.4). Interactive: spawn one
     `opus` agent in the library's checkout (`<parent of this repo's root>/<repo name>`, cloned with
     `gh repo clone` if missing), `description: "upstream <repo>#<n>"`: run the library's
     `/flow:follow-through <n>`, then its Workflow → Release as a patch; report the version. Tell the
     user it is running and where.
9. **Hand off:** the upstream link, the adoption issue, the proposed API in two sentences, the
   workaround in use until the release.
