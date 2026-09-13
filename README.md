# zoolutions/claude-plugins

Claude Code marketplace for the zoolutions, hldesign and getzazu repositories. The rule that shapes it: **knowledge lives in each repository; the machinery that reads and grows it lives here.** A plugin here never carries facts about one codebase.

| Plugin | What it does |
|---|---|
| [`lode`](plugins/lode) | Durable per-repo memory in `lode/` (Lode Coding by fjzeit) plus a pre-PR gate: fresh-context reviewers check the branch diff against the repo's rules and its own review learnings, every new test is proven to fail without the change, and nothing pushes until the gate has passed. Accepted findings are written back so the next gate is stricter. |

## Enable in a repository

Commit this in the repository's `.claude/settings.json`; everyone who clones it gets the plugin:

```json
{
  "extraKnownMarketplaces": {
    "zoolutions": { "source": { "source": "github", "repo": "zoolutions/claude-plugins" } }
  },
  "enabledPlugins": { "lode@zoolutions": true }
}
```

Then, once per repository, `/lode:seed` builds the lode and opens the PR that turns the gate on. `/lode:seed` does that settings edit for you.

## Try it on one machine

```bash
claude plugin marketplace add zoolutions/claude-plugins
claude plugin install lode@zoolutions
```

## Updating

Third-party marketplaces do not auto-update. `claude plugin marketplace update zoolutions` then `claude plugin update lode@zoolutions`, or turn on auto-update for this marketplace under `/plugin`. The checklists in `plugins/lode/checklists/` change most often; a repo's gate reads whatever version is installed.

## Contributing a learning

`/lode:learn` in any repository opens a PR here when a finding applies to more than one codebase. Hand-written PRs follow the same rule: one bullet per PR, in the matching checklist, naming the repos it was seen in. Changes to the agents or skills are deliberate and reviewed by a maintainer.
