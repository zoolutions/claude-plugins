---
name: release
description: Cut a release of a Ruby library the way the release kit does it — roll the changelog into the version's heading through a PR, run the repository's release script from a clean main, then verify the publish, RubyGems and the docs deploy. Use when merged work should ship, or as the release step /flow:follow-through and /flow:plan upstream run after a library fix (`/ruby-gem:release patch`).
argument-hint: "patch | minor | major | X.Y.Z (empty = derived from the changelog; a level is a floor the changelog can raise)"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill, AskUserQuestion
model: opus
---

# Release: $ARGUMENTS

`main` below is the default branch: Workflow → Base when set, else `main`.

Ship what `main` holds. **Read the repository first:** `AGENTS.md` → `## Workflow` → **Release**
names the release command, the changelog and its heading, prep commands, the lockfiles that pin the
gem, the docs deploy and any human step. Verify, Merge and PR contract apply to the changelog PR. A
missing label means "none"; no Release line → stop, this repository is not released this way.

**Unattended.** Exactly two things ask (`AskUserQuestion`, once): a major bump, or a changelog with
nothing to ship. Under an orchestrator there is no one to ask: those two, and every blocker outside
the repository, end the run as `needs-user` with the reason.

**The kit does the release.** `bin/release` → `rake release[X.Y.Z]` (`rakelib/release.rake`) bumps
`version.rb` and every tracked lockfile pin in place (no re-resolve), builds, commits, pushes `main`
and creates the GitHub Release whose `release.yml` publishes to RubyGems. This skill does what the kit
leaves out — the changelog — and checks what it starts. The kit's files are byte-identical across
the gems (canonical copy in docs-kit): never edit them here.

## Phase 1: State and a clean clone

The kit runs only on a clean `main` equal to `origin/main`, and working trees are usually on feature
branches (a worktree on `main` fails while `main` is checked out elsewhere). Work in a throw-away
clone; every command below runs there (`cd <clone> && …` when the shell does not keep the directory):

```bash
clone="$(mktemp -d)/$(basename "$(git rev-parse --show-toplevel)")"
gh repo clone "$(gh repo view --json nameWithOwner --jq .nameWithOwner)" "$clone" -- --branch main
cd "$clone" && bundle install --quiet && bin/release list
```

`bin/release list` prints the gemspec version, the last tags and what each bump gives.

- **Resume.** An open roll PR (`gh pr list --state open --json number,headRefName --jq '.[] |
  select(.headRefName | startswith("release/v"))'`): its branch names the target → Phase 3 on it. A
  `v<X.Y.Z>` tag with a GitHub Release → Phase 5 only.
- **Version already moved.** The gemspec version is above the newest tag and has no tag (a feature PR
  bumped `VERSION`): that version is the target; the kit skips the bump.

## Phase 2: Version

Read the section to ship: `## [Unreleased]` (or `## Unreleased`), or, in a changelog without one, the
version heading above the last released one.

| The section holds | Level |
|---|---|
| a removal, a renamed public name, a behaviour change named as one, an "Upgrading" or "BREAKING" note | major (on `0.x`: minor) |
| an addition (`Added`, a new option, method or class) | minor |
| only fixes, performance, docs | patch |

- An argument level is a floor: the changelog may raise it, never lower it. `X.Y.Z` is taken as given.
- Current version is a prerelease (`alpha|beta|rc|pre`): a level bump *finalises* it (9.0.0.alpha2 →
  9.0.0), so it counts as major unless an explicit prerelease version was passed.
- **Ask** when the result is major (offer it, the next lower level, stop), or the section has no bullet
  (offer: write the bullets from the PRs merged since the last tag, `gh pr list --state merged
  --search "merged:>=<last tag date>"`; or stop).

Then `bin/release <X.Y.Z> --dry-run`: it must print `release: v<X.Y.Z>` and no "cannot release"
blocker. A blocker names a gem in a tracked lockfile that pins this one below the new version: that
gem releases first (its own `/ruby-gem:release`), or `needs-user` naming it.

## Phase 3: Roll the changelog (a PR)

`git switch -c release/v<X.Y.Z>` in the clone (resuming an open roll PR: `git fetch origin
release/v<X.Y.Z>` and `git switch release/v<X.Y.Z>` instead, then continue where it stops), then in
`CHANGELOG.md`:

1. **Missed releases.** Every `v*` tag newer than the newest version heading gets its heading (date:
   `git log -1 --format=%cs <tag>`) with the bullets whose PR it shipped (`git tag --contains <merge
   sha>`; bullets cite `#N`). This drift is why "changelog headings match what each release shipped"
   commits exist.
2. **The new heading.** Copy the shape of the previous release heading exactly: brackets or none, `-`
   or `—`, `(date)` or `- date`, a compare link when the file keeps them. Today's date. Above it a fresh
   empty `[Unreleased]` in the file's spelling, only if the file has one; category stubs only if the
   previous roll left them.
3. **Already headed** (the heading for `<X.Y.Z>` was written by the feature PRs): nothing to roll.
4. **Prep.** Run Workflow → Release → prep (a re-recorded baseline when the version string changes a
   measured file); commit what it writes.

Never touch `version.rb` or the lockfile pins here: the kit bumps them in its own commit. Nothing
changed → skip to Phase 4. Otherwise commit (`docs(changelog): <X.Y.Z>`), push, `gh pr create` with
Workflow → PR contract, and `/flow:finish-prs <PR> automerge` (Skill tool) from the clone. Parked →
`needs-user` with its reason.

**Human step** (Workflow → Release → human, e.g. reader checks that cannot run in CI): put it in the
PR body as a checklist, comment it on the PR with the resume command `/ruby-gem:release <X.Y.Z>`, and
end as `needs-user` before merging. A re-run with the checklist ticked by the operator continues.

## Phase 4: Release

```bash
git switch main && git pull --ff-only origin main && bundle install --quiet
bin/release <X.Y.Z> --dry-run            # same version, no blocker, the roll is in the change list
printf 'y\n' | bin/release <X.Y.Z>       # explicit version: main may have moved since Phase 2
```

The kit's own guards (branch, clean tree, `HEAD == origin/main`, tag absent, `release:preflight`)
abort before anything is pushed: read the message, fix the cause, run again. A rejected push to `main`
(a ruleset that admins cannot bypass) publishes nothing: `needs-user`, never a bypass.

## Phase 5: Verify

1. The publish — this release's run, never just the latest: `gh run list --workflow release.yml
   --limit 20 --json databaseId,headBranch,headSha,status,conclusion --jq '.[] | select(.headBranch ==
   "v<X.Y.Z>" or .headSha == "<the tag's commit>")'` (none yet: it is still starting, ask again), then
   `gh run watch <id> --exit-status` (Bash timeout 600000; re-run until it finishes). A job waiting on
   an environment approval → `needs-user`.
2. RubyGems: `curl -fsS https://rubygems.org/api/v2/rubygems/<gem>/versions/<X.Y.Z>.json` (the index
   lags a few minutes; retry).
3. Docs (Workflow → Release → docs): watch that workflow's run for the release the same way.
4. **Red publish.** `gh run view <id> --log-failed`. A frozen `bundle install` failing on a stale
   lockfile → a PR that re-locks that file (`bundle install` in its directory), through `/flow:finish-prs
   <PR> automerge`, then `printf 'y\n' | bin/release <X.Y.Z> --force` once. The publish skips a version
   already on RubyGems, so a re-cut never double-publishes. Anything else → the same fix-PR-then-re-cut,
   or `needs-user` when the cause is outside the repository.
5. `rm -rf` the clone.

## Report

One line: `released <gem> v<X.Y.Z> — <release URL>` or `needs-user — <reason>`; under an orchestrator,
the version and that state in its JSON.

## Never

- Edit `bin/release`, `rakelib/release.rake` or `release.yml`'s shared jobs; `gem push`; `git tag`;
  `git push --tags`.
- Bump `version.rb` or a lockfile pin by hand, or re-resolve a lockfile, for a release.
- `--force` except the one re-cut after a fixed publish failure.
- Release from a branch, a dirty tree or a `main` behind `origin/main`.
