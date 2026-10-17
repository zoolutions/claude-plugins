# ruby-gem

For Ruby libraries, next to `flow`. Every fact these skills act on comes from the repository's
`AGENTS.md` → `## Workflow`; nothing here is specific to one repository.

```bash
claude plugin install ruby-gem@zoolutions
```

| Skill | What it does | Model |
|---|---|---|
| `/ruby-gem:release [patch\|minor\|major\|X.Y.Z]` | Rolls `CHANGELOG.md` into the version's heading through a PR (`/flow:finish-prs <that PR> automerge`), runs `bin/release <X.Y.Z>` from a clean clone of `main`, watches `release.yml`, checks RubyGems and the docs deploy. Asks only for a major bump or an empty changelog; parks on a **human** step. `/flow:follow-through` runs it as `patch` after an upstream fix. | opus |
| `/ruby-gem:perf [bench]` | Branch against `main` (in a worktree), same machine, same harness; time and allocations, honest about noise and level. | sonnet |

The release kit (`bin/release`, `rakelib/release.rake`, `release.yml`'s shared jobs) stays in each
repository, byte-identical, copied from one canonical repository. `release` drives it and never edits it.

Enable it as the marketplace README shows, with `"enabledPlugins": { "flow@zoolutions": true,
"ruby-gem@zoolutions": true }`.

## The `## Workflow` lines a gem adds

Besides the lines every repository has (Verify, Specs, CI, Review bot, Merge, PR contract, Conflicts,
Worktree setup, Main health, Upstream), a gem adds Release and Bench, and its Conflicts line carries
the changelog rule:

```markdown
- **Release:** `bin/release <v>`; changelog `CHANGELOG.md`, heading `## [X.Y.Z] - YYYY-MM-DD` under `## [Unreleased]`; prep none; lockfiles `Gemfile.lock` `docs/Gemfile.lock`; docs `deploy-docs.yml` on release; human none
- **Bench:** `bundle exec rake bench`, one `bundle exec rake bench:one[<name>]`; hot paths `docs/performance.md`; CI holds none
- **Conflicts:** `CHANGELOG.md` — both sides' bullets, each under its own heading; a bullet both sides changed takes main's; re-read the section after the merge
```

- **heading** is the shape `release` copies for the new version (brackets, dash, date form). A
  changelog without `[Unreleased]` says so (`heading ## X.Y.Z - YYYY-MM-DD, written in the feature PR`).
- **lockfiles** are the tracked ones that source the gem (`gemspec` or `path: ".."`, e.g. a `docs/` app).
  The kit bumps their pin in the release commit; `bin/release --dry-run` names a dependent gem whose lock
  refuses the new version. A PR that moves `VERSION` itself re-runs `bundle install` in each.
- **prep** runs in the changelog PR (e.g. `bundle exec rake metrics:update` when the version string is
  in a measured file). **human** is a step no agent can do (a manual reader check); `release` parks on it.
- **Bench** `none` → `perf` writes a scratch script; **CI holds** names a committed baseline CI compares.
- The changelog conflict rule is a Conflicts line, not a skill: `/flow:finish-prs` and
  `/flow:github-review-pr` already resolve conflicts by Workflow → Conflicts.

