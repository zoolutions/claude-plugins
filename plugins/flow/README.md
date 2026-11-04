# flow

The engineering workflow every repository shares. Costs nothing until a skill is invoked; no hooks,
no gates, no memory layer.

```bash
claude plugin install flow@zoolutions
```

| Skill | For |
|---|---|
| `/flow:lfg <issue>` | Issue → merge-ready PR: understand, plan, TDD, verify, `flow:fable-validator` by rigor tier, PR, then `/flow:finish-prs` until CI is green and every thread is answered. Never merges |
| `/flow:follow-through <epic \| issues>` | Epic → merged, unattended: dependency waves, one Opus agent per issue in its own worktree, `/flow:finish-prs automerge`, upstream library fixes carried to a release and an adoption issue. `--dry-run` prints the waves |
| `/flow:finish-prs [prs] [automerge]` | Ordered PRs → merge-ready in review rounds; `automerge` merges (or queues) once mergeable, green, thread-free, review-bot-approved and validated per its rigor tier; a queue also needs main green |
| `/flow:plan [issue\|md\|upstream <owner/repo>] …` | A self-contained plan as an issue or markdown, with an effort estimate; `upstream` plans a public library issue and, for a library we own, carries the fix through |
| `/flow:effort <pr> [--write]` | The PR body's `## Effort & cost`: time, tokens per role and model, validation passes, review rounds, diff, against the estimate. `/flow:lfg` writes it when the PR opens, `/flow:finish-prs` refreshes it before the hand-off |
| `/flow:github-review-pr <pr>` | One pass: conflicts → CI failures → review threads |
| `/flow:github-review-failures <pr>` | Fix every red check (merge-queue evictions included) |
| `/flow:github-review-comments <pr>` | Fix or answer every review thread, bots included |
| `/flow:tdd <behaviour>` | RED → GREEN → REFACTOR |
| `/flow:review-pr <pr> [post]` | Bugs and rule breaches, confidence-scored |
| `/flow:debug-flaky <run \| pr \| test>` | Root-cause an intermittent failure; never a retry or sleep |

## The `## Workflow` section

Every fact the skills act on comes from the repository's `AGENTS.md`, one line per label. A missing
label means "none". Keep it true of the tree; keep it short.

```markdown
## Workflow

- **Verify:** <commands run before every commit>
- **Specs:** fast loop `<cmd> <file>`; full suite `<cmd>`; changed `<cmd running the tests for the diff against base>`; two worktrees at once: <yes | how>
- **Agents:** at most <n> at once (missing: 3); max load <x>× cores (missing: 1.5)
- **CI:** required `<check>`; jobs `<names>`; full suite on <the PR | the merge queue>; failure report <marker | none>
- **Review bot:** cubic | coderabbit | none
- **Merge:** queue — `gh pr merge <PR> --match-head-commit <sha>` | squash — `gh pr merge <PR> --squash --delete-branch`; optional fallback after the gate: `--admin` for <the protection the gate covers>
- **PR contract:** <required body sections in order, label rule, screenshots rule>
- **Conflicts:** `<file>` — <rule>; …
- **Worktree setup:** <commands with <N> = issue or PR number, and how to undo them | none>
- **Release:** <`bin/release <v>` / `/ruby-gem:release` | none>; changelog <path | none>
- **Main health:** <command printing success/failure for main> (missing: the skills read the CI status of main's head, never assume green)
- **Upstream:** libraries we own `<owner/*>`; scrub `<denylist command | none>`
- **Bench:** <benchmark command for /ruby-gem:perf | none>
- **Rigor:** `<path to the rigor file>` (missing: every change is critical)
- **Base:** <default branch, when it is not `main`>
```

`changed` is the local gate when CI runs the full suite (on the PR or in the merge queue); without
that CI fact the full suite runs locally. `Agents` caps how many agents `/flow:follow-through` keeps
alive; before each spawn, and before `/flow:lfg`'s heavy steps, `load.rb` checks the machine's load
against `max load`: busy slows a run down, never stops it.

## Rigor: how hard a change is validated

`skills/lfg/rigor.rb` classifies a change against the repository's rigor file. `/flow:lfg` Phase 6.5
and `/flow:finish-prs` 2e then spend validation by tier:

| Tier | `flow:fable-validator` |
|---|---|
| light | none: Workflow → Verify and the review bot are the gate |
| standard | one pass for a clean verdict. A BLOCK is re-validated. Notes are fixed or rebutted and never re-run. Stops after three BLOCKs. The validator does not call the advisor |
| critical | the full loop: blockers and code-changing notes are fixed and re-validated. Notes rebutted without a code change end the loop. Stops after three code-changing answers or three BLOCKs in a row, whichever comes first |

```yaml
version: 1
default: standard                    # a file no rule matches gets this tier
critical:
  paths:   ["app/services/payments/", "db/migrate/**"]
  signals:                           # Ruby regexps on ADDED lines only
    - "with_lock"                    # any file
    - { pattern: "_cents\\b", paths: ["app/**"] }   # only added lines in these files
  labels:  ["risk:high"]
light:
  paths:   ["docs/**", "**/*.md"]
```

The rules:
- A change takes the highest tier that any of these reaches: a changed path, a signal on an added
  line, or a PR label.
- Renames match on both paths, and a deleted file counts too.
- Signals and labels only ever raise the tier.
- Globs are `File.fnmatch` with `FNM_PATHNAME | FNM_EXTGLOB | FNM_DOTMATCH`. `dir/` and `dir/**` mean
  everything under `dir`.
- The configuration comes from the base, so a change never chooses its own gate. `--base` reads
  AGENTS.md and the rigor file at `git merge-base <base> HEAD`; `--since <sha>` reads them at that
  sha. `--files -` (planning, no diff yet) and an explicit `--config <path>` read the working tree.
- A change to the gate is critical, with a `config` reason: one that touches the base's rigor file,
  adds or removes a `**Rigor:**` line in AGENTS.md, or leaves a Workflow Rigor line that names
  another file or none (say, after renaming the heading above it).
- First adoption: when the base has no Rigor line, or lacks the file it names, the working tree's
  configuration is read with a warning, and the change is critical too. The fallback never lowers
  the tier.
- Every unknown state prints `critical`: no Rigor line, a missing or invalid file, a Rigor path
  outside the repository, or a git error. That is how flow validated before tiers existed, so an
  error never lowers the bar.
- `/flow:lfg --rigor <tier>` raises the tier. A lower tier needs `--why`, and the reason goes into the
  PR body. An orchestrator never lowers the tier.

```bash
ruby skills/lfg/rigor.rb --base origin/main [--summary | --json] [--labels a,b]
printf '%s\n' <paths> | ruby skills/lfg/rigor.rb --files -     # planned files, no diff yet
ruby skills/lfg/rigor.rb --since <sha>                          # only this PR's own commits since <sha>
```
