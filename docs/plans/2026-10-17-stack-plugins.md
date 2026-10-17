# Stack plugins replace lode

Status: approved 2026-10-17 (split, SDK autonomy and upstream depth chosen by the maintainer).

## Why

`lode` spent tokens on every push (fresh-context gate reviewers, a push hook, a ledger, a memory
layer, rigor tiers) and no repository kept it enabled. Meanwhile the thing it was meant to fix got
worse: the same workflow is hand-copied into every repository and has drifted everywhere.

Inventory of the 29 repositories in scope, default branch, 2026-10-17:

| File | Repos carrying it | Distinct versions |
|---|---|---|
| `.claude/commands/lfg.md` | 26 | 26 |
| `.claude/commands/github-review-pr.md` | 26 | 26 |
| `.claude/commands/github-review-comments.md` | 26 | 26 |
| `.claude/commands/github-review-failures.md` | 25 | 25 |
| `.claude/commands/plan.md`, `tdd.md`, `review-pr.md` | 17 each | 17 each |
| `.claude/agents/fable-validator.md` | 25 | 17 (the 8 SDK clients share one) |

Always-loaded context per session (AGENTS.md + CLAUDE.md + `.claude/rules/`): 9–53 KB, of which
`.claude/rules/` is 6–32 KB in most repositories. Every session pays it before the first prompt.

A fix to the workflow (`/follow-through`, `/finish-prs automerge`, findings fixed
in the round they appear) reaches one repository at a time, by hand.

## Shape

**Knowledge stays in each repository; machinery lives here, once.** No hooks, no gates, no memory
layer, no per-push agents. A plugin costs nothing until one of its skills is invoked (only the
one-line descriptions are listed).

| Plugin | For | Skills / agents |
|---|---|---|
| `flow` | every repository | `lfg`, `plan` (incl. upstream mode), `tdd`, `review-pr`, `github-review-pr`, `github-review-failures`, `github-review-comments`, `finish-prs`, `follow-through`, `debug-flaky`; agent `fable-validator` |
| `rails-app` | the Rails applications | the layer specialists (`models`, `controllers`, `views`, `jobs`, `services`, `database`, `security`, `i18n`, `mailers`, `stimulus`, `tests`, `architect`, …), `appsignal-debug`, `appsignal-triage` |
| `ruby-gem` | the zoolutions libraries | `release` (version, CHANGELOG `[Unreleased]`, frozen lockfiles, `bin/release`), `perf` (benchmark a branch against main), `upstream-sync` |

A repository enables `flow` plus its stack plugin in a committed `.claude/settings.json`
(`extraKnownMarketplaces` + `enabledPlugins`). It keeps locally only what is truly its own (an SEO routine, a component generator, a production
cherry-pick, a release train).

## The `## Workflow` facts contract

Every fact the `flow` skills act on comes from one section of the repository's `AGENTS.md`, which
every agent already loads. No second profile file (lode's `workflow.md` duplicated AGENTS.md and
drifted from it). Target: under 1.5 KB. Each line is a fact, true of the tree as it is.

```markdown
## Workflow

- **Verify:** `bundle exec rubocop -A` · `bundle exec rspec <specs>` · `bundle exec brakeman --quiet` · …
- **Specs:** fast loop `<cmd> <file>`; full suite `<cmd>`; two worktrees at once: <yes | how to isolate>
- **CI:** required `<check>`; jobs `<names>`; full suite on <the PR | the merge queue>; failure report `<marker or none>`
- **Review bot:** cubic | coderabbit | none
- **Merge:** queue — `gh pr merge <PR> --match-head-commit <sha>` | squash — `gh pr merge <PR> --squash --delete-branch`; optional fallback after the gate: `--admin` for <the protection the gate covers>
- **PR contract:** <required body sections, labels rule, screenshots rule>
- **Conflicts:** `<file>` — <rule>; …
- **Worktree setup:** <commands, or none>
- **Release:** <`bin/release <v>` | none>; changelog <path | none>
- **Main health:** <command that prints success/failure for main, or "CI status of main's head">
- **Upstream:** libraries we own `<owner/*>`; scrub `<denylist command, or none>`
- **Bench:** <benchmark command for /ruby-gem:perf | none>
```

The skills name these by label ("AGENTS.md → Workflow → Merge"). A missing label means "none".

## `flow`: what changes from today's best copies

Built from the two most recent copies: one written for a merge queue, one for direct squash merges.

- `lfg` ends with `finish-prs <PR>` in default mode: rounds of conflicts → CI → review threads until
  merge-ready. It never merges.
- `follow-through <epic | issues>`: dependency waves, one Opus agent per issue in its own worktree
  (Workflow → Worktree setup), `finish-prs automerge`.
- `finish-prs automerge` gate: mergeable · checks green · zero open threads · review bot approved the
  head (cubic: latest review APPROVED on `headRefOid`; coderabbit: its check green and no open thread;
  none: skipped) · main green · `fable-validator` PASS. Then Workflow → Merge (queue or squash).
- Every finding is fixed or answered in its round; nothing deferred, nothing left to the user as a
  choice. Unattended runs park only on blockers outside the repository.
- `plan upstream <owner/repo>` for a `zoolutions/*` library: file the issue (scrubbed, as today), then
  hand it to the library: its `follow-through <issue>` (fix, review, merge) and its release (Workflow →
  Release, patch bump), then file an adoption issue in the calling repository ("bump <gem> to <v>,
  drop the workaround at <file>") that names the upstream issue. Under a `follow-through` run the
  adoption issue joins the run once the release is published. Other owners: draft only, the operator
  files it.

## API clients: `flow` only

The generated API clients need nothing beyond `flow`: their review bot is cubic, and their release
train is specific to one product and describes its staging environment, so it stays a private
command in the application that drives it. Its human gates change there:

- Patch and minor: no prompt. Version derived from the API diff, cassettes recorded against staging,
  every SDK released, CLI and docs updated.
- Major (or a cross-SDK API decision such as a new error class): one question at the version step.
  Everything after it runs unattended.

## Rollout

1. This repository: remove `plugins/lode`, add the three plugins, update `marketplace.json` and
   README. One PR.
2. One PR per repository (29), each: enable the plugins, write the `## Workflow` section, delete the
   local copies the plugins replace, fold `.claude/rules/*` into AGENTS.md (or delete what AGENTS.md
   already says), keep only repo-unique commands. Each PR states the always-loaded bytes before and
   after.
3. Order: the two reference repositories first, then the other libraries, then the applications,
   then the API clients (their application first, since it drives the train).

Every machine needs the marketplace once: `claude plugin marketplace add zoolutions/claude-plugins`,
and `claude plugin marketplace update zoolutions` after a plugin change (or auto-update on).
