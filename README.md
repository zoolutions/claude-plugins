# claude-plugins

A Claude Code plugin marketplace. **Knowledge lives in each repository; the machinery lives here,
once.** A plugin never carries facts about one codebase, ships no hooks, gates or memory layers, and
costs nothing until one of its skills is invoked.

| Plugin | For | What it does |
|---|---|---|
| [`flow`](plugins/flow) | every repository | `/flow:lfg` (issue → merge-ready PR, never merges), `/flow:follow-through` (epic → merged, unattended: dependency waves, one agent per issue, upstream fixes carried to a release), `/flow:finish-prs` (review rounds until green; `automerge` merges or queues), `/flow:plan` (incl. `upstream`, with an effort estimate), `/flow:effort` (each PR's time and tokens against the estimate), `/flow:github-review-pr` / `-failures` / `-comments`, `/flow:tdd`, `/flow:review-pr`, `/flow:debug-flaky`, the `flow:fable-validator` agent |
| [`rails-app`](plugins/rails-app) | Rails applications | the layer specialists, AppSignal debugging and triage |
| [`ruby-gem`](plugins/ruby-gem) | Ruby libraries | an unattended release, branch-versus-main benchmarks |
| [`machine`](plugins/machine) | every machine agents run on | `/machine:reap`: reports and reaps the processes agent sessions leave behind, keeps test runs at background priority; schedule and SessionStart line wired per machine |

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

## Set up a machine (once)

The trust prompt installs only in a folder that was not trusted yet. A checkout trusted before, and
every new worktree path, reports the plugin as "enabled in project settings but isn't installed".
Install them once, at user scope:

```bash
claude plugin marketplace add zoolutions/claude-plugins   # skip if `claude plugin marketplace list` has it
claude plugin install flow@zoolutions --scope user
claude plugin install rails-app@zoolutions --scope user
claude plugin install ruby-gem@zoolutions --scope user
claude plugin install machine@zoolutions --scope user
```

`install --scope user` also writes `"<plugin>@zoolutions": true` to `~/.claude/settings.json` →
`enabledPlugins`, which turns the plugin on in every repository. Delete the keys of `flow`,
`rails-app` and `ruby-gem`. Don't set them to `false`: a repository that enables the plugin loads it anyway and warns on every load. With
no user-level key, a plugin installed at user scope stays off until a repository's
`.claude/settings.json` enables it. A running session picks it up with `/reload-plugins`.

`machine` is the exception: it cares for the machine, not a repository, so keep its user-level key.
Its schedule and SessionStart line are installed by the machine's own setup:
[`plugins/machine/README.md`](plugins/machine/README.md) → Wiring a machine.

## Changing a plugin

A plugin change reaches every repository at once, so write it for all of them: no repository names,
paths or tools in a skill — a fact one repository needs goes in that repository's `## Workflow`
section, and the skill names the label. `claude plugin validate plugins/<name>` before the PR;
`claude plugin details <name>` shows what a skill costs in context. A script a skill runs ships beside
its `SKILL.md`, stdlib only, and has its tests in `test/` (outside the plugins, so they do not ship):
`ruby test/effort_test.rb`, `ruby test/machine_test.rb`.
