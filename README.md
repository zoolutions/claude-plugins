# claude-plugins

A Claude Code plugin marketplace. **Knowledge lives in each repository; the machinery lives here,
once.** A plugin never carries facts about one codebase, ships no hooks, gates or memory layers, and
costs nothing until one of its skills is invoked.

| Plugin | For | What it does |
|---|---|---|
| [`flow`](plugins/flow) | every repository | `/flow:lfg` (issue → merge-ready PR, never merges), `/flow:follow-through` (epic → merged, unattended: dependency waves, one agent per issue, upstream fixes carried to a release), `/flow:finish-prs` (review rounds until green; `automerge` merges or queues), `/flow:plan` (incl. `upstream`), `/flow:github-review-pr` / `-failures` / `-comments`, `/flow:tdd`, `/flow:review-pr`, `/flow:debug-flaky`, the `flow:fable-validator` agent |
| [`rails-app`](plugins/rails-app) | Rails applications | the layer specialists, AppSignal debugging and triage |
| [`ruby-gem`](plugins/ruby-gem) | Ruby libraries | an unattended release, branch-versus-main benchmarks |

## What each repository keeps

- `AGENTS.md` with a `## Workflow` section: the facts the `flow` skills act on, one line each —
  Verify, Specs, CI, Review bot, Merge, PR contract, Conflicts, Worktree setup, Release, Main health,
  Upstream, Bench, and Base when the default branch is not `main`. Template and rules: [`docs/plans/2026-10-17-stack-plugins.md`](docs/plans/2026-10-17-stack-plugins.md).
- `CLAUDE.md` as a one-line `@AGENTS.md` import.
- `.claude/settings.json` enabling `flow` and its stack plugin.
- Only the commands that are truly its own.

## Enable in a repository

```json
{
  "extraKnownMarketplaces": {
    "zoolutions": {
      "source": { "source": "github", "repo": "zoolutions/claude-plugins" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "flow@zoolutions": true, "<stack plugin: rails-app or ruby-gem>@zoolutions": true }
}
```

After the workspace trust prompt Claude Code clones the marketplace and installs the enabled plugins
(their sources are relative paths in this repository). `autoUpdate` keeps them current; the plugins
carry no `version`, so every commit to `main` is the release. By hand:
`claude plugin update flow@zoolutions`.

## Try it on one machine

```bash
claude plugin marketplace add zoolutions/claude-plugins
claude plugin install flow@zoolutions
```

## Changing a plugin

A plugin change reaches every repository at once, so write it for all of them: no repository names,
paths or tools in a skill — a fact one repository needs goes in that repository's `## Workflow`
section, and the skill names the label. `claude plugin validate plugins/<name>` before the PR;
`claude plugin details <name>` shows what a skill costs in context.
