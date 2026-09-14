# claude-plugins

A Claude Code plugin marketplace. The rule that shapes it: **knowledge lives in each repository; the machinery that reads and grows it lives here.** A plugin here never carries facts about one codebase.

| Plugin | What it does |
|---|---|
| [`lode`](plugins/lode) | Three layers. **Memory**: `lode/` per repo (Lode Coding by fjzeit), with `lode/review/` holding accepted review findings as rules. **Gate**: fresh-context reviewers check the branch diff against the repo's rules and lode, every new test is proven to fail without the change, and a hook refuses any push until the gate has passed. **Workflows**: `/lode:lfg`, `/lode:review-pr`, `/lode:finish-prs`, `/lode:debug-flaky`, `/lode:tdd`, `/lode:plan`, one copy for every repository, reading `lode/workflow.md` for what differs, including how much rigor a change there buys (its **Rigor** tier: critical, standard or light, per path). |

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

Then, once per repository, `/lode:seed` builds the lode, writes `lode/workflow.md`, retires the repo's local copies of the workflow commands, and opens the PR that turns the gate on. `/lode:seed` does that settings edit for you. A repository that already has a lode runs `/lode:seed workflow` to add the profile.

## Try it on one machine

```bash
claude plugin marketplace add zoolutions/claude-plugins
claude plugin install lode@zoolutions
```

## Updating

Third-party marketplaces do not auto-update. `claude plugin marketplace update zoolutions` then `claude plugin update lode@zoolutions`, or turn on auto-update for this marketplace under `/plugin`. The checklists in `plugins/lode/checklists/` change most often; a repo's gate reads whatever version is installed.

## Contributing a learning

`/lode:learn` in any repository opens a PR here when a finding applies to more than one codebase. Hand-written PRs follow the same rule: one bullet per PR, in the matching checklist, describing the failing case and the safe direction without naming the repository it came from. Changes to the agents or skills are deliberate and reviewed by a maintainer.
