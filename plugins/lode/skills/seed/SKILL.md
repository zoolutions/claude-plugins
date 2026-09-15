---
name: seed
description: Create a repository's lode from scratch and turn on the pre-PR gate; with "workflow", write or refresh lode/workflow.md (the profile the shared /lode:lfg, /lode:review-pr and sibling skills read) from CLAUDE.md, the rules and any local commands, leaving the local copies of those commands in place as the fallback. Builds summary, terminology, practices, the map and one folder per subsystem from the code as it is; imports the repo's existing review learnings (cubic via MCP, and accepted findings from merged PR review threads) into lode/review; enables the plugin in .claude/settings.json; opens the PR. Run once per repository, or again with "audit" to reconcile a lode with the code.
argument-hint: "[audit | workflow]"
allowed-tools: Bash(*), Read, Grep, Glob, Edit, Write, Agent, Skill
---

# /lode:seed

Lode Coding's rule for an existing codebase: the assistant reads the code, drafts the lode, and the human refines it in conversation. This skill does the reading and drafting, seeds the review rules the repository has already paid for, and leaves a PR the maintainers can correct line by line. Every fact it writes is one it read, and where it cannot check a claim against the code it says so in the PR body instead of filling the gap.

## 0. Branch

```bash
git fetch -q origin && git switch -c chore/lode origin/main   # or the repo's default branch
```

If `lode/` already exists and the argument is `audit`, skip to step 5. If the argument is `workflow`, do only step 4a and step 6 on a `chore/lode-workflow` branch. With no argument and an existing `lode/`, write `lode/workflow.md` if it is missing — step 4a, on the `chore/lode-workflow` branch — and otherwise run `audit`.

## 1. Read the repository

Read `CLAUDE.md`, `AGENTS.md`, `README.md`, every `.claude/rules/*.md`, the architecture or module layout, the test directory layout, and the CI workflow. Use an Explore agent for the sweep of large trees; read the load-bearing files yourself. Note every fact you will write down and the file it came from. The lode is not allowed to say what the README says without checking the code agrees.

## 2. Write the baseline

```
lode/
  summary.md        one paragraph: what the system is, for whom, its two or three non-negotiable invariants
  terminology.md    `term — meaning` lines for the domain language, including the repo's own jargon
  practices.md      patterns that are not already in .claude/rules (link to those, do not duplicate them)
  lode-map.md       hierarchical index of every lode file with a one-line purpose each
  review/           one file per area, seeded in step 3
  plans/README.md   where plans live — an existing plans directory or the issue tracker — so `/lode:plan --file` has a path to write to; do not move existing plans
  tmp/              add `lode/tmp/` to .gitignore
  <area>/summary.md one per subsystem named in the architecture: invariants, contracts, the shape of its data, a Mermaid diagram where a flow exists
```

Each file covers one topic, stays under 250 lines (if the `Write` tool refuses a `summary.md`, write it with a shell heredoc; the refusal is a harness guard against report files, not a rule of the lode), states current behaviour with its rationale, and links related files by relative path. Every claim is checkable against the code; where a doc and the code disagree, write what the code does and list the disagreement in `lode/tmp/seed-discrepancies.md` for the PR body — never as a section inside a lode file, which would describe a state the same PR is about to change. Compute every line range (`def` to its `end`) and every count with a script and paste the output — a citation read off the screen is off by a few often enough that the gate's claims agent catches it; `${CLAUDE_PLUGIN_ROOT}/checklists/docs-claims.md` is the list of shapes it checks.

## 3. Seed `lode/review/`

Two sources, both used when available:

- **cubic learnings.** If the `mcp__cubic__list_learnings` tool is available, call it for this repository. Each learning is a review rule the maintainer accepted. Convert each to the `/lode:learn` entry shape (rule about the system, holds-because, where, safe direction, origin = the learning id) in `lode/review/<area>.md`. Rewrite review-voice ("when reviewing X, flag Y") into system-voice ("X does Y because Z"). Drop learnings that describe a file that no longer exists.
- **Merged PR review threads.** `gh pr list --state merged --limit 30`, then for each PR the review comments and the author's replies. A finding the author accepted becomes an entry; one the author rejected with a reason becomes a `### Not a bug:` entry. This source works for repositories without cubic and for CodeRabbit and human reviews.

Verify each rule against the current code before writing it (step 2 of `/lode:learn`). Add every `lode/review/` file to the map.

## 4. Enable the plugin

Merge into `.claude/settings.json` without disturbing existing keys:

```json
{
  "extraKnownMarketplaces": {
    "zoolutions": { "source": { "source": "github", "repo": "zoolutions/claude-plugins" } }
  },
  "enabledPlugins": { "lode@zoolutions": true }
}
```

Add to `CLAUDE.md`, near the top, so tools that do not run the SessionStart hook still find the lode:

```markdown
## Memory
Durable project memory lives in `lode/` (index: `lode/lode-map.md`). Read it before exploring. `lode/review/` holds accepted review findings as rules; `/lode:gate` enforces them before any push, and `/lode:learn` adds to them.
```

If the repo has an implementation workflow command (`/lfg` or similar), add one line to its verify phase: "When the lode plugin is enabled, run `/lode:gate` and paste its report into the PR body before `gh pr create`." Do not restructure the command; it must keep working with the plugin turned off.

## 4a. The workflow profile

The shared workflow skills (`/lode:lfg`, `/lode:review-pr`, `/lode:finish-prs`, `/lode:debug-flaky`, `/lode:tdd`, `/lode:plan`) are one copy for every repository; `lode/workflow.md` is what makes them behave as if written for this one. Copy `${CLAUDE_PLUGIN_ROOT}/templates/workflow.md` to `lode/workflow.md` and fill every heading from three sources, in this order of authority: the code and config as they are (commands that exist, workflows that run), `CLAUDE.md` and `.claude/rules/*.md`, and any local `.claude/commands/{lfg,github-review-pr,github-review-failures,github-review-comments,finish-prs,debug-flaky,tdd,plan}.md` — those carry the repo's constraint tables, shape lists, conflict rules and CI quirks, and this is where they move to. Keep every heading even when its body is "none". Run each command under Commands once to prove it exists. Do not copy a rule that `.claude/rules` already states; link it.

**Rigor** is the one heading the code cannot answer. Write `Default: standard` and an empty path table unless the user has stated a tier, and list "Rigor: set the default and name the money paths" as a maintainer decision in the PR body. A repo that leaves it at `standard` gets the same review it got before this heading existed; only the gate report gains a Tier line.

Leave the local commands in place. The plugin's skills read the profile; the repository's own `.claude/commands/*.md` (and anything that embeds or points at them — a parallel tooling directory such as `.grok/`, a README table, a skill's "see also" list) keep working exactly as before, so the maintainers can turn the plugin off (`enabledPlugins` in `.claude/settings.json`) and lose nothing until they choose otherwise. Add the `/lode:` names next to the local ones in `CLAUDE.md`'s command table rather than replacing rows, and say in the PR body that both exist and which is the fallback. Retiring the local copies is a separate PR the maintainers open once the plugin has earned it; do not delete, move or thin a local command here.

## 5. Audit (also the `audit` mode)

For every file in `lode/`, check each claim against the code. Fix the lode where the code is right; list the cases where the lode revealed a code problem in the PR body rather than fixing code in a seeding PR.

## 6. PR

The push hook will now demand a gate pass. Run `/lode:gate` on this branch (the rules and claims agents are the relevant ones for a lode PR), then:

```bash
git push -u origin HEAD
gh pr create --repo <owner/repo> --head <branch> --title "chore: seed the lode and enable the pre-PR gate" --body-file <body>
```

Always pass `--repo`: in a fresh clone of a fork, `gh` defaults to the fork parent and opens the PR on the wrong repository.

The body lists: the files created, the number of review rules imported and from which source, every doc-versus-code disagreement found, which local commands the plugin's skills now duplicate and that they stay as the fallback, and the gate report.
