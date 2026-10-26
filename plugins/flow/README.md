# flow

The engineering workflow every repository shares. Costs nothing until a skill is invoked; no hooks,
no gates, no memory layer.

```bash
claude plugin install flow@zoolutions
```

| Skill | For |
|---|---|
| `/flow:lfg <issue>` | Issue → merge-ready PR: understand, plan, TDD, verify, `flow:fable-validator`, PR, then `/flow:finish-prs` until CI is green and every thread is answered. Never merges |
| `/flow:follow-through <epic \| issues>` | Epic → merged, unattended: dependency waves, one Opus agent per issue in its own worktree, `/flow:finish-prs automerge`, upstream library fixes carried to a release and an adoption issue. `--dry-run` prints the waves |
| `/flow:finish-prs [prs] [automerge]` | Ordered PRs → merge-ready in review rounds; `automerge` merges (or queues) once mergeable, green, thread-free, review-bot-approved and validator PASS; a queue also needs main green |
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
- **Base:** <default branch, when it is not `main`>
```

`changed` is the local gate when CI runs the full suite (on the PR or in the merge queue); without
that CI fact the full suite runs locally. `Agents` caps how many agents `/flow:follow-through` keeps
alive; before each spawn, and before `/flow:lfg`'s heavy steps, `load.rb` checks the machine's load
against `max load`: busy slows a run down, never stops it.
