# lode

Three things, kept apart on purpose.

**The lode** is a repository's durable memory: `lode/` in the repo, plain markdown, tool-agnostic, following [Lode Coding](https://fjzeit.github.io/lode). It describes the system as it is now, with rationale, invariants and lessons. `lode/review/` is the part this plugin adds: every review finding the maintainers accepted, rewritten as a rule about the system, so it is read before the next diff is written rather than after.

**The gate** is what runs before a push. Reviewers with no memory of the conversation read the diff, the repo's rules and its lode, and report only what they can state as a failing input. New tests are proven to fail without the change. Findings are fixed and re-reviewed — each round on the delta of the last round's fixes, so only the first round on a branch reads the whole diff — until none at P1 or P2 remain or the tier's round cap is reached; P2s left at the cap are deferred into the PR body, a P1 blocks. A `PreToolUse` hook on `Agent` refuses a gate spawn past that cap, outside the tier's set, or with a model override. A `PreToolUse` hook on Bash then refuses `git push` and `gh pr create` unless `lode/tmp/gate-passed` names the current `HEAD^{tree}`. It sees only commands issued through the Bash tool, and it fails open — no git, no JSON parser, input it cannot parse, and it allows; only an explicit tree mismatch denies.

**The workflows** are the engineering playbooks, one copy for every repository: implement to a PR, drive a PR to merge-ready, land a stack, root-cause a flake, test-first, plan. What differs between repositories is not the shape of the work; it is the commands, constraints, shapes, conflict rules and CI quirks. Those live in one profile per repository, `lode/workflow.md` (template in `templates/workflow.md`), which the skills read instead of carrying facts about any one codebase.

## Skills

| Skill | When |
|---|---|
| `/lode:seed` | once per repository: build the lode from the code, import existing review learnings (cubic via MCP, merged PR threads via `gh`), enable the plugin, open the PR |
| `/lode:gate` | before every push; at the verify phase of `/lfg` or any implementation workflow |
| `/lode:learn` | after review comments are processed, after a gate, or with a finding in words: write the rule into `lode/review/`, promote it here if it generalises |
| `/lode:sync` | after "ship it", after any behaviour change, `audit` to reconcile with the code, `handover` for a fresh session |
| `/lode:lfg` | implement a feature, an issue or a plan file end to end: branch → understand → explore → plan → TDD → verify → gate → PR, with a deviation log and a comprehension close-out |
| `/lode:review-pr` | a PR needs a full pass: merge conflicts, then CI failures, then review comments, in that order and for a stated reason; one phase on request |
| `/lode:finish-prs` | land several open PRs in a given order, one at a time, stacks included |
| `/lode:debug-flaky` | an intermittent test: evidence → forced reproduction → root cause → a proof that fails on the old code → its own PR; never a retry, sleep or skip |
| `/lode:tdd` | RED → GREEN → REFACTOR in whatever framework the repo's rules name |
| `/lode:plan` | read-only design before `/lode:lfg`; produces an issue or a plan file with binding Decision and Out of scope sections |

Every workflow skill starts by reading `lode/workflow.md` and `lode/lode-map.md`, with `CLAUDE.md` and `.claude/rules/` behind them. Without the profile it says so, derives what it can, and keeps going.

## Agents

`gate-correctness`, `gate-rules`, `gate-claims`, `gate-tests`, `gate-parser`. Each is a fresh context with one lens and a strict output format. See `agents/`.

## Hooks

- `PreToolUse` on Bash: denies `git push` and `gh pr create` unless `lode/tmp/gate-passed` names the tree at `HEAD`. Allows, with a message on stderr, when the repo has no `lode/`, so enabling the plugin before seeding blocks nobody; allows the same way on anything it cannot parse. Bypass with `LODE_SKIP_GATE=1` and say why in the PR.
- `PreToolUse` on Agent: denies a `lode:gate-*` spawn that `scripts/gate-ledger.sh` refuses — no `begin` on this branch, no `round` yet, an agent outside the tier's set, a `model` override on an agent whose definition declares one, or an agent already spawned as many times as the tier's round cap in this invocation. Any other agent, an unparseable input, or a repo without `lode/` is allowed; `LODE_SKIP_GATE=1` bypasses it the same way.
- `SessionStart`: prints `lode/summary.md` and `lode/lode-map.md` into context.

## Checklists

`checklists/*.md` are failure classes seen in more than one repository. The gate agents read them alongside `lode/review/`. They grow through `/lode:learn` PRs.

## The profile

`lode/workflow.md` has eleven fixed headings: Commands, Branches and PRs, Layers, Shapes, Constraints, Docs, CI, Flake sources, Conflicts, Verification, Rigor. `/lode:seed` writes it from the code, `CLAUDE.md`, the rules and any local commands it retires; `/lode:sync` keeps it true when a command or a workflow changes; the gate's claims agent audits it like any other lode file, so a command that no longer exists is a finding.

## Rigor tiers

Not every repository is a money path, and not every path in one is. The **Rigor** heading names a default tier and a table of path patterns that raise or lower it; `scripts/rigor.sh` classifies a diff as the highest tier any changed file matches (a file no rule names counts as the default) and prints `standard` when the heading is absent, so a repo seeded before the heading existed behaves as it did. `/lode:gate`, `/lode:lfg`, `/lode:review-pr`, `/lode:finish-prs` and `/lode:plan` take `--tier <t>` to override; lowering needs `--why "<reason>"`, which the gate writes into its report and the PR body, and which `/lode:plan` records in the plan's Decision section. `/lode:tdd`, `/lode:debug-flaky`, `/lode:learn`, `/lode:sync` and `/lode:seed` do not change with the tier.

| | light | standard | critical |
|---|---|---|---|
| gate agents | tests, rules (+ parser when the diff parses) | + correctness, claims, pstack when installed | + a second correctness pass on the concurrency checklist only |
| gate rounds (also each agent's spawn cap per gate) | 1 | 3 | 5 |
| `/lode:learn` after the gate | only when a finding was confirmed | always | always |
| `/lode:lfg` | comprehension questions 1, 3, 5; no Explore agent; deviation log only on a deviation; close-out without merge-gate questions | full | full, and refuses a critical path without an issue or plan carrying a Decision section |
| `/lode:review-pr`, `/lode:finish-prs` | one gate and one push per review-pr pass; finish-prs leaves its merge commit to that pass | one per phase, each on that phase's delta | one per phase, each on that phase's delta |
| `/lode:plan` | no subagents for a small sweep; at most one interview question; options may be one paragraph | full | full |

The push hook does not change with the tier: at every tier a push needs a gate pass on the exact tree, short of the `LODE_SKIP_GATE=1` emergency bypass, which was there before tiers and ignores them.

## The gate ledger

`scripts/gate-ledger.sh` keeps `lode/tmp/gate/ledger`, one per branch: what the agents have already seen and what the current gate invocation has spent. `begin` starts an invocation (tier, cap, counters); `round` writes `diff.patch` (the whole branch, context) and `delta.patch` (what the agents review — the full diff the first time, afterwards each commit's own diff since the last round, and a merge commit's combined diff, which is empty for a clean merge-forward and holds only the resolution for a resolved conflict); `pass` writes `lode/tmp/gate-passed` after `/lode:learn` has committed, so the stamped tree already holds the new rules and no second gate follows; `show` prints the Spent block every gate report and review-pr pass ends with. `pass` refuses a dirty tree and an open P1. A merge whose combined diff is empty can still hide a semantic conflict across files; the push hook, CI and review-pr's Phase A are what catch that.

## Working with pstack

If [pstack](https://github.com/michael-denyer/pstack-claude) is installed, `/lode:gate` also runs `pstack:interrogate` for multi-model diversity at the standard and critical tiers and merges its *Act on* findings; the light tier skips it. pstack's playbooks and principles govern how work is done; this plugin governs what the repository remembers and what may be pushed. They compose.
