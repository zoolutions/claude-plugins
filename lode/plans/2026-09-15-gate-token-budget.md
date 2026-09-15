# Gate token budget

## Problem

`/lode:gate` spends hundreds of thousands of tokens on diffs that have almost nothing for most of its agents to do. Evidence: [zoolutions/importmap-plus#30](https://github.com/zoolutions/importmap-plus/pull/30) — 16 markdown files, +155/−1272, no Ruby — running four gate agents in parallel on Fable 5.1 / Sonnet, each already at 79–106k tokens after two minutes, parent at 116k (~490k in flight).

Done looks like: that shape of PR buys two Sonnet reviewers (rules + claims), one round, no Fable inherit, no mutation worktree, and the parent does not re-read the same 29k-token context pack the agents will read.

## Context (read these first)

| File | Why | Edit rule |
|---|---|---|
| `plugins/lode/skills/gate/SKILL.md` | Fan-out, "read these files first", "pass paths not contents" | owned here |
| `plugins/lode/agents/gate-*.md` | Each lens's required reading and method | owned here |
| `plugins/lode/scripts/gate-ledger.sh` | Tier's agent set, `round` writes both patches | owned here |
| `plugins/lode/scripts/test/gate_ledger_test.sh` | The contract the skip logic must extend | owned here |
| `plugins/lode/scripts/rigor.sh` | Highest-tier-wins; a file no rule names is the default | owned here |
| `plugins/lode/templates/workflow.md` | Seeded Rigor table | owned here |
| `plugins/lode/skills/seed/SKILL.md` | Already says a lode PR wants rules + claims; gate ignores that | owned here |
| `plugins/lode/README.md` | Rigor table restated | owned here |

## What PR 30 actually spent

Measured on `importmap-rails` at `chore/lode-workflow`, ledger after `begin` + `round`:

```
tier=standard  cap=3  kind.1=full  delta.1=1583
spawned=gate-tests:sonnet, gate-rules:sonnet, gate-correctness:inherit, gate-claims:sonnet
```

`gate-correctness` declares `model: inherit`, so it ran as Fable 5.1 with the parent.

Required reading each agent is told to finish before the diff (~29k tokens × 4):

- `CLAUDE.md` + six `.claude/rules/*.md` (~10k)
- `lode/workflow.md` + `practices.md` + every `lode/review/*.md` (~15k), including cli/packager/inspection rules that cannot apply to this diff
- every plugin checklist, including parsers and concurrency (~4k)

Plus both `delta.patch` and `diff.patch` (97k each, byte-identical on round 1) if they follow "when two patches are named" (~24k × 2 × 4).

Then they wander: the screenshot has `gate-rules` grepping the repo for stale command references and `gate-correctness` verifying `ci.yml` matrix count. Those are in-scope for a claims/rules audit of `workflow.md`; they are not a reason to also spawn tests and a Fable correctness pass.

### Why it was `standard`

importmap-plus already maps `docs/`, `lode/`, `.claude/`, `CLAUDE.md`, `README.md` to `light`. Per-file:

| Path | Tier |
|---|---|
| `.claude/commands/*`, `.claude/rules/*` | light |
| `CLAUDE.md`, `lode/**` | light |
| **`.gitignore`** (two-line comment) | **standard** (unlisted → default) |

Drop `.gitignore` from the diff and `rigor.sh` prints `light`. One unlisted file raises the whole fan-out. The template's example light row does not include `.gitignore` or `*.md`; seed writes `Default: standard` and an empty path table unless the user stated one.

Even at `light` the skill still spawns `gate-tests` (nothing to mutate) and still does not spawn `gate-claims` (the agent seed says a lode PR needs). So fixing only the Rigor table is not enough.

## Options considered

- **A — Skip idle agents + stop duplicating context** (chosen). After `round` writes the delta, classify its paths and print the agent list this round may spawn. The hook refuses anything off that list. Agents get only their lens's files; the parent does not slurp the pack; round 1 passes one patch. Correctness pins `sonnet`. Template/seed light rows include the prose paths that actually show up. Chosen because it fixes PR 30 even when Rigor misclassifies, and it does not weaken a code diff's review.
- **B — Default the whole plugin to `light`.** Rejected: money-path repos would silently lose correctness and claims. Tiers exist so a packager change still buys the expensive pass.
- **C — Pre-digest the lode into one `context.md` the four agents share.** Rejected for this PR: Claude Code agents do not share a prefix cache across spawns, so a digest still costs ×N, and writing it is another moving part. Revisit if a harness starts sharing prefixes.
- **D — Shrink SessionStart / thin every skill.** Rejected as the first cut. importmap-plus `summary.md` is 3 lines and `lode-map.md` is 33; SessionStart is not this incident. Skill thinning is a separate PR (lfg 262 lines, review-pr 165) and fights "one home per fact" unless the rigor table is deleted from the skills and left in README.

## Decision

Binding.

1. **Idle skip is a ledger fact, not a prompt hope.** `gate-ledger.sh round` classifies the delta's paths and prints `agents=`. `spawn` refuses an agent not on that list (narrower than the tier set, never wider). The skill fans out only those names.
2. **Classification, conservative:**
   - `gate-rules` — always, every tier, every non-empty delta.
   - `gate-tests` — a path under a test directory (`test/`, `spec/`, `tests/`, `features/`) or matching `*_test.*`, `*_spec.*`, `*.test.*`, `*.spec.*`.
   - `gate-parser` — unchanged: the existing `grep -E` on the patch, all tiers.
   - `gate-correctness` — standard/critical, and the delta is not prose-only.
   - `gate-claims` — standard/critical, and the delta has prose. **Also at `light` when the delta has prose** (this is the lode-PR hole: seed already asked for claims; light currently drops it).
3. **Prose-only** means every changed path is one of: `*.md`, `*.mdx`, `*.txt`, `*.rst`, `*.adoc`, `LICENSE*`, `CHANGELOG*`, `README*`, `.gitignore`, `.gitattributes`, `.editorconfig`, `.mailmap`, or under `lode/`, `docs/`, `.claude/`. Anything else (`.rb`, `.yml`, `Gemfile`, `*.json`, CI, source) is source. A diff that mixes prose and source is not prose-only.
4. **One patch on round 1.** `round` already copies `diff.patch` to `delta.patch` when `kind=full`. Print `same=1`. The skill names only `delta.patch` unless `same=0`.
5. **Per-agent context, paths only.** The parent reads `lode/workflow.md` (Commands, Rigor) and the delta path list. It does **not** read CLAUDE.md, rules, review, or checklists — Claude Code already injected CLAUDE.md, and the agents will read what they need. Preamble lists only that agent's files:

   | Agent | Context |
   |---|---|
   | tests | `checklists/tests.md`; `lode/review/testing.md` if present; the single-file test command |
   | rules | `CLAUDE.md`, `.claude/rules/*.md`, `lode/practices.md`, `lode/review/*.md` whose area the delta touches (plus `lode/review/` files the map labels repo-wide). Checklists: none by default; the review files and CLAUDE.md are the rules. |
   | claims | `checklists/docs-claims.md`; `lode/review/` for docs/changelog if present; the PR body / `intent.md` |
   | correctness | `checklists/error-handling.md`, `files-and-io.md`; at critical also `state-and-concurrency.md`. In-scope `lode/review/`. Not the parser or tests checklists. |
   | parser | `checklists/parsers.md` only |

   "In-scope review" = a `lode/review/<area>.md` whose `<area>` is a prefix of a changed path, or that `lode-map.md` names for a changed path. If the map does not resolve any, pass every `lode/review/*.md` (today's behaviour, fail open).
6. **Delta first.** Every agent prompt: read `delta.patch` first; open a context file only if a rule in it could apply to a path in the delta; do not grep the rest of the repo except for a companion the rule names (changelog line, docs page, fixture). Correctness siblings stay in files the delta already touches.
7. **`gate-correctness` model: `sonnet`.** `inherit` made it Fable because the parent was Fable. Critical's second concurrency pass stays a second spawn of the same agent (still sonnet). A later PR can introduce a stronger model at critical; this one stops the accidental upgrade.
8. **Template / seed Rigor.** Default stays `standard`. The seeded path table is no longer empty:

   ```
   | `docs/`, `lode/`, `.claude/`, `*.md`, `.gitignore` | light |
   ```

   Seed still records "name the money paths" as a maintainer decision. README and the template both state: **one unlisted file raises the whole diff to the default.**
9. **Out of scope for this PR:** SessionStart dump, thinning lfg/review-pr, a shared context digest, changing round caps, pstack, making default tier light.

`Settled in interview:` none yet — implement against this Decision; stop and ask if a skip rule would drop correctness from a diff that contains source.

## Changes, file by file

| File | Change | Edit rule |
|---|---|---|
| `plugins/lode/scripts/gate-ledger.sh` | `round` classifies paths, writes `agents.<n>=`, prints `agents=` and `same=`; `spawn` intersects with that list | owned here |
| `plugins/lode/scripts/test/gate_ledger_test.sh` | RED cases below | owned here |
| `plugins/lode/skills/gate/SKILL.md` | Fan-out from `agents=`; one patch when `same=1`; per-agent context lists; parent does not slurp the pack; parser grep only if parser is in `agents=` | owned here |
| `plugins/lode/agents/gate-*.md` | Delta first; only the lens's checklist; in-scope review; no repo-wide grep except named companions | owned here |
| `plugins/lode/agents/gate-correctness.md` | `model: sonnet` | owned here |
| `plugins/lode/templates/workflow.md` | Light row as in Decision 8; one-unlisted-file sentence | owned here |
| `plugins/lode/skills/seed/SKILL.md` | Write that light row; keep "rules and claims for a lode PR" and make it true | owned here |
| `plugins/lode/README.md` | Light agents: tests if tests, claims if prose; idle skip; correctness is sonnet | owned here |
| `plugins/lode/checklists/README.md` | Rules no longer reads every checklist | owned here |
| `plugins/lode/.claude-plugin/plugin.json`, marketplace, root README | 0.5.0 | owned here |

## Shapes to handle

- Prose-only delta at standard (PR 30): `agents=gate-rules,gate-claims`.
- Prose-only delta at light: `agents=gate-rules,gate-claims` (claims added).
- Test-only delta at standard: `agents=gate-rules,gate-tests,gate-claims?` — claims only if a markdown fixture/doc is also in the delta; usually `gate-rules,gate-tests`.
- Source + tests at standard: today's four, plus parser if the grep hits.
- Source at light (a `docs/` Ruby page mapped light): `gate-rules` + `gate-tests` if tests, no correctness (tier), no claims unless prose.
- Empty delta (`delta_lines=0`): no fan-out, unchanged.
- Mixed `.rb` + `.md`: not prose-only; correctness stays.
- `.yml` / `Gemfile` / `package.json`: source, not prose.
- `kind=full` and `kind=delta` both classify from `delta.patch`'s `+++ b/` paths (the files this round reviews), not from the whole branch.
- Parser grep still runs on `diff.patch` or `delta.patch`? On `delta.patch` — later rounds should not re-litigate unchanged parsers.

## Test plan

`bash plugins/lode/scripts/test/gate_ledger_test.sh` — add cases in the existing `check`/`contains` style, in a throwaway repo like the others.

RED first, against current `round` (no `agents=` line) and current `spawn` (tier set only):

1. Feature commit is `feature.txt` (source): `round` prints `agents=` containing `gate-rules` and `gate-correctness` and `gate-tests` only if a test path is present (the fixture's `t/a_test.sh` is on main, not in the delta) → **no tests in the delta → no gate-tests**.
2. Commit only `README.md`: `agents=` is `gate-rules,gate-claims`; spawn of `gate-tests` and `gate-correctness` denied; spawn of `gate-claims` allowed at standard.
3. Same README commit at `--tier light --why docs`: `agents=` includes `gate-claims`; spawn of claims allowed (today denied).
4. `kind=full`: `same=1`. After a second commit, `same=0`.
5. Spawn of an agent in the tier set but not this round's `agents=` is a refusal that names the round's list.
6. Critical source delta still allows two `gate-correctness` spawns per round.
7. Empty-ish: existing `delta_lines=0` behaviour unchanged.

No Ruby/JS test runner in this repo; the ledger tests are the suite. Run them after the script is green, then a dry read of the skill against the new `round` keys.

## Docs and changelog

- `plugins/lode/README.md` Rigor table and The gate ledger paragraph.
- Root `README.md` only if the one-line plugin blurb must mention idle skip (it should not; keep it short).
- No user-facing changelog file in this repo; the version bump and README are the record.

## Risks and rollback

- **False skip of correctness** on a config-only diff (`.yml` that changes CI behaviour). Mitigated by classifying yaml/json/toml/Gemfile as source. If we still skip one, the human reviewer and CI remain; revert the classifier.
- **Claims at light increases spend** on a docs typo. One Sonnet agent, one round, vs today's tests+rules with a useless mutation worktree. Net down on PR 30; acceptable if a one-line README is slightly up.
- **In-scope review miss** if `lode-map.md` does not name the area. Fail open to all `lode/review/*.md`.
- Rollback: revert the 0.5.0 PR; the hook fails open on an old ledger without `agents.N=`, so a mid-air mix of versions must **fail open to the tier set** when `agents.N` is missing.

## Acceptance criteria

- GIVEN a diff whose only unlisted-as-light file is `.gitignore` (or a diff of `lode/**` + `.claude/**` + `CLAUDE.md`) WHEN `/lode:gate` runs at the profile default THEN `round` prints `agents=gate-rules,gate-claims` and the hook denies `gate-tests` and `gate-correctness`.
- GIVEN `kind=full` WHEN agents are spawned THEN the preamble names one patch file.
- GIVEN `gate-correctness` WHEN spawned THEN its declared model is `sonnet`.
- GIVEN a `feat` commit that only adds `feature.txt` WHEN `round` runs THEN `agents=` contains `gate-correctness` and does not contain `gate-tests`.
- GIVEN a light prose delta WHEN `spawn lode:gate-claims` THEN the hook allows it.
- GIVEN a ledger from 0.4.0 with no `agents.N` WHEN `spawn` runs THEN the tier set is used (fail open).

## Out of scope

- SessionStart contents, skill thinning, shared context digest, round-cap changes, pstack, default-tier-light, rewriting consumer Rigor tables in other repos (importmap-plus still needs `.gitignore` added to its own table; this PR only changes what new seeds write).

## Lode updates

This marketplace repo has no seeded lode yet. After implementation, `plugins/lode/README.md` is the public description; no `lode/review/` until `/lode:seed` is run here.

## Execution

Implement in this worktree (`feat/gate-token-budget` at `../claude-plugins-token-budget`). TDD on `gate_ledger_test.sh` first. Execute with the Decision and Out of scope as binding.
