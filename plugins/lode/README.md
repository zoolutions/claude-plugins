# lode

Two things, kept apart on purpose.

**The lode** is a repository's durable memory: `lode/` in the repo, plain markdown, tool-agnostic, following [Lode Coding](https://fjzeit.github.io/lode). It describes the system as it is now, with rationale, invariants and lessons. `lode/review/` is the part this plugin adds: every review finding the maintainers accepted, rewritten as a rule about the system, so it is read before the next diff is written rather than after.

**The gate** is what runs before a push. Reviewers with no memory of the conversation read the diff, the repo's rules and its lode, and report only what they can state as a failing input. New tests are proven to fail without the change. Findings are fixed and re-reviewed until none at P1 or P2 remain. A hook refuses `git push` and `gh pr create` until that has happened on the exact tree being pushed.

## Skills

| Skill | When |
|---|---|
| `/lode:seed` | once per repository: build the lode from the code, import existing review learnings (cubic via MCP, merged PR threads via `gh`), enable the plugin, open the PR |
| `/lode:gate` | before every push; at the verify phase of `/lfg` or any implementation workflow |
| `/lode:learn` | after review comments are processed, after a gate, or with a finding in words: write the rule into `lode/review/`, promote it here if it generalises |
| `/lode:sync` | after "ship it", after any behaviour change, `audit` to reconcile with the code, `handover` for a fresh session |

## Agents

`gate-correctness`, `gate-rules`, `gate-claims`, `gate-tests`, `gate-parser`. Each is a fresh context with one lens and a strict output format. See `agents/`.

## Hooks

- `PreToolUse` on Bash: denies `git push` and `gh pr create` unless `lode/tmp/gate-passed` names the tree at `HEAD`. Allows silently when the repo has no `lode/`, so enabling the plugin before seeding blocks nobody. Bypass with `LODE_SKIP_GATE=1` and say why in the PR.
- `SessionStart`: prints `lode/summary.md` and `lode/lode-map.md` into context.

## Checklists

`checklists/*.md` are failure classes seen in more than one repository. The gate agents read them alongside `lode/review/`. They grow through `/lode:learn` PRs.

## Working with pstack

If [pstack](https://github.com/michael-denyer/pstack-claude) is installed, `/lode:gate` also runs `pstack:interrogate` for multi-model diversity and merges its *Act on* findings. pstack's playbooks and principles govern how work is done; this plugin governs what the repository remembers and what may be pushed. They compose.
