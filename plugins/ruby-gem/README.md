# ruby-gem

For the zoolutions Ruby libraries, next to `flow`. Every fact these skills act on comes from the
repository's `AGENTS.md` → `## Workflow`; nothing here names a repository.

```bash
claude plugin install ruby-gem@zoolutions
```

| Skill | What it does | Model |
|---|---|---|
| `/ruby-gem:release [patch\|minor\|major\|X.Y.Z]` | Rolls `CHANGELOG.md` into the version's heading through a PR (`/flow:finish-prs automerge`), runs `bin/release <X.Y.Z>` from a clean clone of `main`, watches `release.yml`, checks RubyGems and the docs deploy. Asks only for a major bump or an empty changelog. `/flow:follow-through` runs it as `patch` after an upstream fix. | opus |
| `/ruby-gem:perf [bench]` | Branch against `main` (in a worktree), same machine, same harness; time and allocations, honest about noise and level. | sonnet |

The release kit (`bin/release`, `rakelib/release.rake`, `release.yml`'s shared jobs) stays in each
repository, byte-identical, with docs-kit as its canonical home. `release` drives it and never edits it.

Enable it as the marketplace README shows, with `"enabledPlugins": { "flow@zoolutions": true,
"ruby-gem@zoolutions": true }`.

## The `## Workflow` lines a gem adds

Besides the lines every repository has (Verify, Specs, CI, Review bot, Merge, PR contract, Worktree
setup, Main health):

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

## Stays local

| Repository | Keeps | Why |
|---|---|---|
| importmap-plus | `upstream-sync` (+ its rule) | the only live fork: merges rails/importmap-rails tags |
| docs-kit | `release-kit` | rolls the kit out from its canonical copy |
| daisyui | `add-component`, `audit-components`, `check-component`, `fix-docs-tests`, `test-all` | component work against the DaisyUI docs |
| each gem | `architect`, `security` (or folded into AGENTS.md) | its own layers and threat surface |
| dash-proxy | `perf` | Go (`make bench`) |

dash and dash-proxy's `upstream-sync` rules are retirement notes: fold the surviving facts (proxy image
before gem, no suffix tags) into AGENTS.md. The `perf` copies in pgbus, phlex-reactive, stationery,
glyphs, importmap-plus and dash go; their hot-path tables belong in the doc the Bench line names.

## Fit

| Repository | `release` |
|---|---|
| pgbus, phlex-reactive, phlex-forms, docs-kit, glyphs, locallingo, daisyui | fits |
| importmap-plus | fits: `VERSION` is often bumped in a feature PR, so the target is that version |
| conformance-kit | fits: no `[Unreleased]`, headings written in feature PRs, so the roll is usually empty |
| dash | fits: `release:preflight` aborts until the dash-proxy image tagged `MINIMUM_VERSION` exists |
| stationery | fits with **human**: the Acrobat reader checklist parks every release; **prep** `bundle exec rake metrics:update` |
| sidekiq-unique-jobs | partly: a 9.0 prerelease line (any level bump finalises 9.0.0, so it asks) and a generated changelog; pass the explicit version |
| dash-proxy | no: Go, tag-only `vX.Y.Z.N`, no version file or changelog. `flow` only, Release `bin/release` |
