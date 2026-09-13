---
name: lfg
description: The full autonomous engineering workflow, from an empty branch to an open PR. Use when implementing a feature, taking on a GitHub issue, or executing a plan file — understand, explore, plan, TDD, verify, gate, PR, and a comprehension close-out. Not for a one-line fix or a question.
argument-hint: "<GitHub issue number or URL | path to a plan file | a description of the work>"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent, Skill
---

# /lode:lfg

One pass from nothing to a reviewable PR, with a check at every phase. The phases are the same in every repository; every fact they act on comes from the repository itself.

## Read the repository first

Before Phase 0, read in this order:

1. `lode/workflow.md` — the profile. Its headings (Commands, Branches and PRs, Layers, Shapes, Constraints, Docs, CI, Flake sources, Conflicts, Verification) are what the phases below point at by name.
2. `CLAUDE.md` — the never-do list there binds every phase.
3. `.claude/rules/*.md` — the long form of anything the profile states in a line.
4. `lode/lode-map.md`, then the lode files it indexes for the subsystems you are about to touch, and every `lode/review/*.md` for those areas. Those are findings the repository has already paid for.

If `lode/workflow.md` is missing, say so in your first message, derive what you can from `CLAUDE.md` and `.claude/rules/`, tell the user to run `/lode:seed workflow` to write the profile, and keep going. A missing profile makes you slower, not stuck.

## Phase 0: Branch setup

Before any other work. Read Branches and PRs for the default branch and the branch-name prefixes.

```bash
git fetch origin <default>
git switch -c <prefix>/<slug> origin/<default>
```

Never branch off an existing feature branch unless the work is deliberately stacked on an open PR — say so in the PR body when it is.

## Phase 1: Understand

### 1.1 Gather requirements

- An issue number or URL: `gh issue view <number> --json title,body,labels,comments`
- A plan file: read it. Its Decision and Out of scope sections are binding.
- A description: use it as given.

### 1.2 Acceptance criteria

Mandatory, and written before anything else, as GIVEN / WHEN / THEN. THEN is the observable outcome a test can assert — the exact output, the exact stored value, the exact rendered result. Vague THENs produce vague tests.

### 1.3 Comprehension gate

You must be able to state all five before proceeding:

1. The problem or feature in one sentence.
2. WHY it is needed — what a user of this system runs into today.
3. What changes from the user's perspective.
4. Edge cases nobody mentioned: take them from the profile's Shapes, which lists the inputs, states and environments this repository's changes are judged against.
5. The code path, named in the terms of the profile's Layers: which layers it crosses, and for each file, what Layers says about editing it.

If you cannot complete all five, investigate further. This gate is the cheapest phase to fail.

### 1.4 Task list

Write the concrete implementation steps as a task list.

## Phase 2: Explore

1. Sweep for related code with an Explore agent on a cheap model; read the load-bearing files yourself.
2. Walk the layers the change crosses, in the order Layers gives them, and read the tests that already cover each.
3. For every file you intend to edit, apply its Layers edit rule. Owned here: normal rules. Owned elsewhere (upstream, generated, vendored): the rule says what is allowed, and usually it is "additive, in the other owner's style" or "edit the source instead".
4. Find the docs that describe the behaviour, using the mapping rule under Docs.
5. Read the existing tests for the same behaviour before writing a new one. Matching the house shape matters more than your preferences.

## Phase 3: Plan

1. Files to modify, with the specific change in each and its Layers edit rule.
2. New files to create. New behaviour of any size belongs in its own file rather than growing an existing one.
3. Tests first: which file gets a case, whether a new fixture is needed, and whether a slow or external-dependency test is justified — the profile's Commands says which suite pays that cost.
4. The docs page and changelog entry required by Docs.
5. Backwards compatibility: does existing data, configuration or output written before this change still work after it? Does anything this change writes still work for a consumer that predates it?
6. Check the design against Constraints. If your plan matches a row there, it is the wrong plan in this repository, whoever suggested it.

## Phase 4: Implement (TDD)

### The deviation log

The plan is the map; the codebase is the territory. The moment reality forces a choice the plan or issue did not settle, log it in `lode/tmp/implementation-notes.md` — one line, at the moment it happens, never reconstructed later:

- **Deviations** — the plan said X, you did Y, because Z
- **Discoveries** — facts about the codebase the plan did not know
- **Judgment calls** — choices the user might have made differently: defaults, naming, wording, scope cuts

Pick the conservative option and keep going. `lode/tmp/` is git-ignored, and `/lode:seed` adds that ignore, so the log never lands in a commit; its contents move into the PR body in Phase 7.

Then, for each logical unit:

### 4.1 Write the failing test first

Run it with the fast-loop command from Commands and watch it fail for the right reason. Failing because the thing you are about to write does not exist yet is right; failing because the fixture is wrong is not.

### 4.2 Implement the minimum

The minimum that passes, in the shape the repository already uses. Every "never do" in `CLAUDE.md`, every rule in `.claude/rules/`, and every entry in `lode/review/` for this area applies here — those are the mistakes this repository has already made once.

### 4.3 Refactor

Once green, tidy — within the edit rule for the file. In a file owned elsewhere, the tidy that costs a future merge is not a tidy.

### 4.4 Validate

Run the fast-loop command for every file you touched, then the lint command from Commands if there is one.

### 4.5 Repeat

Next unit. Mark the task item complete.

## Phase 5: Root cause, not symptom (bug fixes)

### Trace the data

For the value that is wrong: where did it enter the system, what produced it, and what did the code assume at the failure point? Which assumption was violated, and why does an input that violates it exist?

### Use git history

```bash
git log --oneline -20 -- <file>
git blame <file> -L <start>,<end>
```

Who owns this code per Layers, and did a change elsewhere invalidate what it relied on?

### Map all callers

Grep every call site. Does the bug happen in one context only? The answer usually names the fix location.

### Five whys

Keep asking until you reach the point where the error could have been prevented earliest. The best fix is rarely where the error surfaces: fix the producer of the bad value, not the consumer that trips over it; fix the check that let it through, not the line that crashed.

### Unacceptable superficial fixes

- Swallowing an exception to make the symptom disappear
- A nil-safe operator over a nil that means something went wrong
- A guard clause that silently skips the work
- Loosening a pattern or validation until the bad input passes
- A retry, sleep, or skip in a test

These hide the bug. The root cause goes on producing wrong results somewhere else.

## Phase 6: Verify

Run the full suite from Commands, plus lint, plus the docs check if docs changed. If the change touches code the CI matrix varies, run the nearest cell locally — CI says which dimensions differ from local.

A test that fails intermittently is not a flake until proven. Check Flake sources first; if it is not one of them, treat it as a real failure or hand it to `/lode:debug-flaky`. Never paper over it.

Then answer, out loud:

- If I were the user who asked, is this fully resolved?
- Root cause, not symptom?
- Would every new test fail on the default branch?
- Is every entry under Shapes accounted for?
- Does every file owned elsewhere obey its Layers edit rule?

## Phase 6.5: Gate

Commit now — the first commit of the workflow — then hand the branch to reviewers who have not seen this conversation. Each gate round's fixes and the `/lode:learn` write add their own commits on top of it; never amend or squash them.

```bash
git add <specific files>          # never -A: untracked build output is not yours to commit
git commit -m "$(cat <<'EOF'
<type>(<scope>): <subject>

Why this exists, from the user's side. Which invariant shaped the design.

## Test coverage
- <test file>: <what it proves>

Refs #<issue>
EOF
)"
```

Then run `/lode:gate`. It reviews the diff against `CLAUDE.md`, the rules and `lode/review/`, proves every new test fails without the change, and loops until nothing at P1 or P2 remains. Each round's fixes are their own commit, so when the gate is clean the tree is already committed. Let it run `/lode:learn gate`, so the confirmed findings land in `lode/review/` in this same PR, and keep the `## Gate` section it prints.

The push hook refuses `git push` and `gh pr create` until the gate has passed on the exact tree at `HEAD`. Any edit after a pass means another round. If the gate hits its round limit it records no pass and reports why — that is a failure to put in front of the user, not something to push around.

## Phase 7: Push & PR

```bash
git push -u origin $(git branch --show-current)

cat > lode/tmp/pr-body.md <<'EOF'
## Summary
- <the change, by layer>
- Docs updated: <page>
- Changelog entry under <heading>

Closes #<issue>

## Test plan
- [ ] <full suite command> green
- [ ] <the manual check from the profile's Verification, with what to look at>

## Deviations & judgment calls
<lode/tmp/implementation-notes.md, or "None — the plan held.">

## Gate
<the ## Gate section from Phase 6.5>
EOF
gh pr create --title "<type>(<scope>): <subject>" --body-file lode/tmp/pr-body.md
```

Always `--body-file`. It sidesteps shell interpretation entirely, which matters because these bodies quote code. Inside a single-quoted heredoc, backticks and `$` pass through verbatim — never escape them.

The sections come in the order **Branches and PRs** lists them; the four above are the default when it names none. Deviations & judgment calls and Gate go last, and reviewers read those first: one is the audit trail for every decision the plan did not make, the other is what the gate already caught.

If Branches and PRs names a non-default base or an attribution line to add or omit, honour it here.

## Phase 8: Comprehension close-out

The tests prove the code is right; this keeps the user's mental model right. End your final message with:

1. **The decisions, not the diff** — the three to five non-obvious choices someone must understand to maintain this. Lead with the deviation log; the user has not seen it.
2. **Three merge-gate questions** the user should be able to answer before merging. If an answer is not obvious to them, offer a walkthrough. An unanswerable question is comprehension debt, and merging anyway is how it compounds.

## Verification checklist

- [ ] Profile read, or its absence reported and `/lode:seed workflow` recommended
- [ ] Branch rooted off fresh default, per Branches and PRs
- [ ] Acceptance criteria written as GIVEN / WHEN / THEN before any code
- [ ] All five comprehension-gate questions answered
- [ ] Every test written before its implementation and seen red
- [ ] Every entry under Shapes checked
- [ ] Every file owned elsewhere obeys its Layers edit rule
- [ ] Full suite, lint and the nearest CI cell green
- [ ] Docs and changelog updated per Docs
- [ ] `/lode:gate` clean on the exact tree pushed, `/lode:learn gate` run
- [ ] PR body ends with Deviations & judgment calls, then Gate
- [ ] Comprehension close-out delivered

Now execute this workflow for: $ARGUMENTS
