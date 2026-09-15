---
name: learn
description: Write accepted review findings back into the repository's lode as current-state rules so the next /lode:gate enforces them, and promote a finding to the shared plugin checklists when it applies to more than one repo. Run after processing PR review comments (cubic, CodeRabbit, a human), after /lode:gate, or with a finding described in words.
argument-hint: "<PR number> | gate | \"<a finding in words>\""
allowed-tools: Bash(*), Read, Grep, Glob, Edit, Write
---

# /lode:learn

A review finding that was accepted is a fact about the system that nobody had written down. This skill writes it down where the gate will read it, in the form Lode Coding requires: what the system does now and why, never what changed on which day.

## 1. Collect the findings

- **A PR number.** Fetch the review threads (`gh api repos/<owner>/<repo>/pulls/<n>/comments --paginate` and the GraphQL `reviewThreads` query for resolution state). A finding counts as accepted when the author's reply says so ("valid", "fixed in", "agreed", "correct") or the thread was resolved with a code change at that location. A finding the author rejected with a reason counts as a **non-finding** and is recorded as such; it is the cheapest way to stop the same bot raising it next month.
- **`gate`.** Read `lode/tmp/gate/findings.md` (the gate runs learn before it writes its report and records the pass, so the findings file is the source); take every finding with verdict confirmed or confirmed-differently, and every rejected one with a reason.
- **Words.** Take the finding as given, ask nothing, and verify it against the code before writing it.

## 2. Verify against the code

The lode describes the system as implemented. Before writing a rule, read the code it describes and confirm the rule holds *now*, after the fix. If the code and the finding disagree, the code wins and the discrepancy goes in your report, not in the lode.

## 3. Write the rule

Each finding becomes one entry in `lode/review/<area>.md`, where `<area>` is the subsystem from `lode/lode-map.md` (create the file when it is the first finding for that area; add it to the map). Entry shape:

```markdown
### <one-line rule, present tense, about the system>
- **Holds because:** <the failure it prevents, concrete: the input and the wrong outcome>
- **Where:** `<file>#<method>` (and siblings)
- **Safe direction:** <for parsers and validators: which failure is the harmless one and why>
- **Proven by:** `<test file>:<test name>`
- **Origin:** <PR #n | gate <date> | cubic learning <id>>
```

A non-finding gets the same shape under a `### Not a bug: …` heading with the reason in *Holds because*. Keep each file under 250 lines; split by sub-area when it grows past that. Rewrite an existing entry rather than adding a second one on the same rule.

Do not write changelog prose ("we fixed X"). Do not copy the reviewer's sentence; write the rule about the code as it stands.

## 4. Promote what generalises

Ask of each rule: does it mention this repository's own names, or only a class of mistake (a quoting variant, a temp-file race, a fact stated in one doc and not another)? A class-of-mistake rule that another repository could break belongs in the shared checklists, so the gate in every repo learns it.

For those, open a PR against `zoolutions/claude-plugins`:

```bash
TMP=$(mktemp -d) && gh repo clone zoolutions/claude-plugins "$TMP" -- -q --depth 1
cd "$TMP" && git switch -c learn/<slug>
# append one bullet to plugins/lode/checklists/<matching file>.md, in that file's voice, without naming the repository it came from
git commit -am "learn: <rule>" && git push -u origin HEAD
gh pr create --fill --body "<one paragraph: the failing case and the safe direction>."
```

One PR per rule, so each is reviewable on its own. Report the URL. Do not edit the plugin's agents or skills from here; that is a deliberate change, made by hand.

## 5. Commit

Stage only `lode/` and commit on the current branch: `docs(lode): <rule>` for one, `docs(lode): learn from PR #n` for several. The lode change rides in the same PR as the code it describes, so a reviewer sees rule and fix together.

## 6. Report

- Rules written, one line each with the file.
- Non-findings recorded.
- Promotions opened, with PR links.
- Anything the code contradicted and was therefore not written.
