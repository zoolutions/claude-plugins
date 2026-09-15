---
name: gate
description: The pre-PR gate. Run before git push or gh pr create and at the verify phase of any implementation workflow. Fresh-context agents review the branch diff against the repo's rules, its lode and the shared checklists; every new test is proven to fail without the change; findings are fixed and re-reviewed, each round on the delta of the last round's fixes, until no P1 or P2 remains or the tier's round cap is reached (P2s left at the cap are deferred into the PR body; a P1 blocks); then the pass is recorded so the push hook lets the branch through.
argument-hint: "[base ref, default: the profile's default branch] [--rounds N] [--tier critical|standard|light [--why \"<reason>\"]]"
allowed-tools: Bash(*), Read, Grep, Glob, Agent, Edit, Write, Skill
---

# /lode:gate

The author of a diff is the worst reviewer of it. This skill puts the diff in front of reviewers that have never seen the conversation, gives them the repository's own rules and memory, and loops until they are satisfied. It is what an external review bot would do, one round earlier and with the repo's learnings in hand.

The gate reads, in this order: `CLAUDE.md`, every `.claude/rules/*.md`, `lode/workflow.md`, `lode/practices.md`, every `lode/review/*.md`, and the plugin's shared checklists at `${CLAUDE_PLUGIN_ROOT}/checklists/`. If the repo has no `lode/`, stop and run `/lode:seed` first; the gate has nothing to enforce.

## 0. Preconditions

`$ARGUMENTS` carries three optional things: a base ref, `--rounds N`, and `--tier <t>`. The base is the default branch named under **Branches and PRs** in `lode/workflow.md`, or `origin/main` when there is no profile to say. `--rounds N` sets the round cap in step 4; its default depends on the tier. Resolve the base, set `BASE` to it, then:

```bash
git fetch -q origin
git status --porcelain            # must be empty: the gate reviews commits, not a dirty tree
git diff --stat "$BASE"...HEAD
mkdir -p lode/tmp/gate && git log --format='%s%n%n%b' "$BASE"..HEAD > lode/tmp/gate/intent.md
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate-ledger.sh" begin "$BASE" [--tier <t> --why "<reason>"] [--rounds N]   # prints tier=, cap=, invocation=
```

`begin` starts a gate invocation in `lode/tmp/gate/ledger`, the branch's record of what the agents have already seen and what this invocation has spent; the `Agent` hook reads it and refuses a gate spawn it does not allow. The tier is what the profile's **Rigor** heading says for the files this diff touches (`begin` asks `rigor.sh`): the highest tier any changed file matches, else the repo's default, and `standard` when the heading is absent. `--tier <t>` overrides it. Raising is free. Lowering (`--tier light` on a diff the profile calls standard or critical) needs `--why "<reason>"`; `begin` refuses without it. Both the tier and any override travel into the marker and the report below.

If a PR body draft exists (for example `lode/tmp/implementation-notes.md`, or an open PR for this branch via `gh pr view --json body`), append it to `intent.md`. The reviewers judge the diff against the stated intent; an unstated intent is the first finding.

Record the test commands from **Commands** in `lode/workflow.md` — full suite and single file, and `CLAUDE.md` only where there is no profile. The test agent needs the single-file form.

## 1. Fan out

First, every round:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate-ledger.sh" round   # prints round=, range=, delta_lines=
```

It writes `lode/tmp/gate/diff.patch` (the whole `<base>...HEAD`, context) and `lode/tmp/gate/delta.patch` (what the agents review). On a branch the ledger has never seen the delta is the full diff. Afterwards it is only what the branch added since the last round, or since the last gate on this branch: each commit's own diff, and for a merge commit its combined diff, which is empty for a clean merge-forward and holds only the resolution for a resolved conflict. `delta_lines=0` means there is nothing new to review: skip to step 5. `round` refuses past the cap; step 4 says what happens then.

Then one message, parallel `Agent` calls. Every agent gets the same preamble: the paths of `delta.patch` and `diff.patch`, the base ref, the path of `intent.md`, the list of context files above, the instruction to read the context files before the diff, and that findings are on the delta while the full diff is context for reading a hunk. Pass file paths, not contents. Never pass `model`: each agent's definition declares its model, and the hook refuses an override.

| Agent (`subagent_type`) | Tiers | Extra input |
|---|---|---|
| `lode:gate-tests` | all | the single-file test command, the test directory names |
| `lode:gate-rules` | all | |
| `lode:gate-parser` | all, only when the diff touches parsing | run: `grep -E '^\+.*(%r\{|/\\[A-Za-z]|=~|\.match\(|\.scan\(|StringScanner|\.split\(|Regexp|re\.compile|new RegExp)' lode/tmp/gate/diff.patch` and spawn it if anything matches |
| `lode:gate-correctness` | standard, critical | |
| `lode:gate-claims` | standard, critical | the PR body draft, if any |
| `lode:gate-correctness`, second run | critical | the concurrency lens: "Read only `${CLAUDE_PLUGIN_ROOT}/checklists/state-and-concurrency.md` and the concurrency entries under Shapes in `lode/workflow.md`. Walk the diff for concurrent actors only: two callers, a redelivered webhook, a sweep overlapping a user action, a row read outside its lock, a partial write. Report nothing else." |

At `light` the gate is two agents (three when parsing is touched): the mutation check and the rules audit are the two highest-value reviews per token, and the repo's Rigor heading has said the rest is not worth buying here. At `critical` the diff gets a second correctness reviewer whose only lens is concurrency, because that is where money-path defects live and a general pass spreads its attention across everything else.

The hook `scripts/pre-agent-gate.sh` refuses a `lode:gate-*` spawn the ledger does not allow: no `begin` on this branch, no `round` yet, an agent outside the tier's set, a model override, or an agent already spawned as many times as the cap in this invocation (`gate-rules` runs every round, so its count is the round count). A refusal names the limit and what to do; do not spawn around it.

Plugin agents register at session start. If `Agent` answers `Agent type 'lode:gate-…' not found` (the plugin was installed mid-session), spawn `general-purpose` instead and open the prompt with: "First read `${CLAUDE_PLUGIN_ROOT}/agents/<name>.md` and adopt it as your role, method and output format exactly." The result is the same agent; only the registration differs, and the hook cannot see it, so the cap above is yours to keep.

At `standard` and `critical`, if the `pstack` plugin is installed, also invoke `pstack:interrogate` on the same diff; its reviewers run on different models, which is a signal the agents above do not have. Merge only its **Act on** findings. Light does not spend on pstack.

## 2. Merge and verify

Collect every finding into `lode/tmp/gate/findings.md` with: id, agent, severity, file:line, claim, failing case, confidence. Deduplicate findings that describe the same defect from two agents; keep the higher severity and note both sources.

Then verify each P1 and P2 yourself before touching code. Fresh reviewers are wrong sometimes, and usually half-right: the reported failure is not the one that happens, but there is one. Read the code, construct the failing case, run it where you can. Record the verdict per finding: **confirmed**, **confirmed differently** (say how), or **rejected** with the one-line reason. A rejection with no reason is not allowed.

## 3. Fix

For each confirmed P1 and P2, in this order:

1. Write the failing test first, or extend the existing one, and see it fail.
2. Fix the root cause, not the line the finding points at. A finding about one shape usually has siblings in the same file; the correctness agent lists them, fix them together.
3. Apply the repo's own rules to the fix (additive in upstream-owned files, argv arrays for shell-outs, whatever `CLAUDE.md` says).
4. Run the affected test file, then the full suite.
5. Commit with a conventional message that names the finding: `fix: <what>` with the failing case in the body. One commit per logical fix. Never amend or rewrite commits that are already pushed.

P3 findings: fix when the fix is a line or two, otherwise record them as deferred with a reason. A deferred P3 goes in the PR body so a reviewer can disagree.

## 4. Loop

Run `gate-ledger.sh round` again — the delta is now the fix commits — and re-run only the agents whose findings were fixed, plus `gate-rules` always (a fix can break a rule). Stop when a round produces no confirmed P1 or P2, or when `round` refuses because the cap is reached: default 1 at `light`, 3 at `standard`, 5 at `critical`, or `--rounds N` from `$ARGUMENTS`.

At the cap there are no more agents. If no confirmed P1 remains, every remaining confirmed P2 is **deferred**: listed in the report and the PR body under *Deferred at the round limit* with its file and failing case, so the human reviewer sees exactly what was left. A remaining confirmed P1 records no pass: report it and stop. Neither case is a reason to spawn another round.

## 5. Learn

Every **confirmed** finding is a lesson the repository has now paid for. Invoke `/lode:learn gate` now, before the pass is recorded, so its commit sits inside the stamped tree and the rule lands in `lode/review/` in the same PR as the fix. Rejected findings that were plausible teach too: a one-line "not a bug because …" in the relevant `lode/review/` file stops the next reviewer from raising it. At `light`, invoke it only when a finding was confirmed; a clean light round has nothing to write. learn's own commit is not reviewed in this pass; the next gate on the branch reads it as delta.

## 6. Record the pass

Only when the working tree is clean — learn's commit included — and the last round was clean, or the cap was reached with no confirmed P1 left:

```bash
cat > lode/tmp/gate/report.md   # rounds, findings table with verdict and outcome, the deferred list, mutation results, tests run
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate-ledger.sh" pass --deferred <n> --p1 <n>
```

`pass` refuses a dirty tree and an open P1. It writes `lode/tmp/gate-passed`: the `tree=` line the push hook compares with `HEAD^{tree}` (it reads nothing else), plus `tier=`, `override=`, `rounds=`, `agents=` and `deferred=` for the report and the PR body. Any commit after this point invalidates the pass and the gate must run again; a rerun reviews only the delta, so it is one small round, not three.

## 7. Report

End with a section the caller pastes into the PR body:

```
## Gate
Tier: <critical|standard|light>[ (override: <reason>)]. Agents: <names>.
Rounds: N of <cap>. Findings: X confirmed and fixed, Y rejected, Z deferred.
- [P1] <claim> — fixed in <sha>, test <file>:<name>
- [P2] <claim> — rejected: <reason>
- [P2] <claim> — deferred at the round limit: <file>, <failing case>
- [P3] <claim> — deferred: <reason>
Mutation check: all new tests fail on base | <exceptions>
Tests: <command> green
Learned: <lode/review files touched>
Spent: <the output of gate-ledger.sh show — rounds, delta lines per round, agents by name and model>
```

## Escape hatch

`LODE_SKIP_GATE=1 git push` bypasses the hook. Use it for a revert, a hotfix, or a docs typo, and say so in the PR body. Using it on a feature branch defeats the purpose: whatever the gate would have caught goes to the human reviewer, or to production, instead.
