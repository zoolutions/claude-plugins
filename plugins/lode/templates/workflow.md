# Workflow profile

Everything the shared workflow skills (`/lode:lfg`, `/lode:review-pr`, `/lode:finish-prs`, `/lode:debug-flaky`, `/lode:tdd`, `/lode:plan`) need to know about this repository that is not already in `CLAUDE.md`, `.claude/rules/` or the rest of `lode/`. The skills are the same in every repository; this file is what makes them behave like they were written for this one. Keep every heading, even when its body is one line saying "none". Facts here must be true of the tree as it is: a command that no longer exists or a constraint that was lifted is a defect the gate will find.

## Commands

| Purpose | Command | Notes |
|---|---|---|
| fast loop (one file) | `<command with a <file> placeholder>` | |
| full suite | `<command>` | say whether it touches the network or services; safe to run in two worktrees at once? yes/no (shared DB, ports, fixture dirs) |
| lint | `<command or "none">` | |
| one CI cell locally | `<command or "n/a">` | |
| docs build / check | `<command or "n/a">` | |
| run the app | `<command or "n/a">` | |

## Branches and PRs

- Default branch: `main`
- Work branches: `feat/*`, `fix/*`, `chore/*`, `docs/*` … rooted off fresh `origin/<default>`
- Commits: conventional (`feat:`, `fix:` …); the body says why
- PR body sections, in order: Summary, Test plan, Deviations & judgment calls, Gate
- Merge policy: squash on the default branch after green and approval; never rebase a published branch
- Attribution lines to add or omit: <what the repo's or the user's rules say>

## Layers

The architecture as the skills should navigate it: one line per layer with its files, and the edit rule for anything owned elsewhere.

| Layer | Files | Edit rule |
|---|---|---|
| … | … | owned here / upstream-owned (additive only, upstream's style) / generated (edit the source, regenerate) / vendored (never) |

## Shapes

The inputs, states and environments every change must be checked against before it is called done. A reviewer will name the one you forgot.

- <input shape 1, e.g. scoped package names, single-quoted pins, an empty file>
- <state 1, e.g. an existing pin without the new metadata>
- <environment 1, e.g. both asset pipelines, the oldest supported runtime>

## Constraints

Reviewer suggestions that are wrong in this repository, with the reason. `/lode:review-pr` pushes back on these on sight instead of implementing them.

| Suggestion | Why it is wrong here |
|---|---|
| … | … |

## Docs

- User-facing docs live in: `<path>`; how a page maps to a behaviour: `<rule>`
- Changelog: `<path>`, entries go under `<heading rule>`
- A change to `<what>` always updates `<which docs>` in the same PR
- Files that pin a version and drift after a release: `<path>` (regenerate with `<command>`), or none

## CI

- Workflows: `<file>` (what it runs, on what triggers), …
- Matrix: `<dimensions>`; cells that differ from local: `<how>`
- Fetch a failure: `gh run view --job <id> --log-failed` or `<repo-specific>`
- What "green" means: `<all cells | named required checks>`
- Known not-this-branch failures: `<e.g. a pinned lockfile drift on a docs job>`
- Shared or rate-limited services the checks hit: `<e.g. live CDNs, a registry>`, so PRs run one at a time; or none

## Flake sources

The repository's real sources of non-determinism, so `/lode:debug-flaky` starts from evidence rather than suspicion.

- <e.g. live CDN calls in `test/commands_test.rb`>
- <e.g. per-test process forking>
- <e.g. wall-clock or ordering assumptions>

## Conflicts

Per-file rules for `git merge` conflicts, beyond "read both sides".

| File | Rule |
|---|---|
| `<lockfile>` | never hand-merge: take the base's, regenerate |
| `CHANGELOG.md` | union under the same heading, no duplicate subheadings |
| `<registry or routes file>` | append-only, base order first |
| `<fixtures>` | add a second fixture rather than merge two shapes into one |

## Verification

- The manual check a user of this change would do: `<command and what to look at>`
- Stress iterations for a flake proof: `<N>` (the count that makes a race show, e.g. 50)
- Where evidence goes: `lode/tmp/` (never committed) unless the PR needs an auditable trail
