---
name: review-pr
description: Review a pull request for bugs and breaches of the repository's written rules — five parallel reviewers, then an independent confidence score per finding; only findings scoring 80 or more are reported. Read-only; with `post` it posts the review as one PR comment.
argument-hint: "<PR number or URL> [post]"
allowed-tools: Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr list:*), Bash(gh pr comment:*), Bash(gh api:*), Bash(gh issue view:*), Bash(gh search:*), Bash(git log:*), Bash(git blame:*), Bash(git show:*), Bash(git diff:*), Bash(git fetch:*), Read, Glob, Grep, Agent
model: opus
---

# Review PR: $ARGUMENTS

**Read-only.** Read the PR, the code and its history; never check out, build, run, edit, commit or
push. `gh api` is for GET requests. The only write is one `gh pr comment`, and only with `post`.
Every agent spawned here gets this rule in its prompt.

**Read the repository first.** `AGENTS.md` → `## Workflow`: **PR contract** (what the body, labels
and screenshots must carry) and **Review bot** (whose open threads are already findings). A missing
label means "none".

**Report only what should be fixed.** Every reported finding is fixed or answered in its round
(`/flow:github-review-pr`): no "non-blocking suggestions" section. An item is a finding, or noise.

## 0. The PR

- `N`, `#N` or a URL → PR N. Owner and repo come from the PR's URL; a URL for another repository is
  reviewed there (`-R <owner>/<repo>` on every `gh` call). Empty → the open PR for the current branch.
- `post` anywhere → post in step 6. Strip it before parsing.

## 1. Eligibility — one call, inline

`gh pr view <PR> --json state,isDraft,author,headRefOid,baseRefName,title,body,url,files,comments,closingIssuesReferences`

Stop with one line when the PR is closed or merged, a draft, from a bot or purely mechanical (a
lockfile or version bump alone), or already has your comment ending `Reviewed at <headRefOid>`.

## 2. Context

- `gh pr diff <PR>`; the linked issues (`gh issue view`) for intent and acceptance criteria.
- The rule files: `AGENTS.md` and `CLAUDE.md` at the root and in every ancestor directory of a changed
  file, and the files they import (`@path`).
- The review bot's threads on this PR (Workflow → Review bot): what it already raised is not repeated.
- A file at the PR's head: `git fetch https://github.com/<owner>/<repo> pull/<PR>/head` (the PR's own
  repository, not this checkout's `origin`), then `git show FETCH_HEAD:<path>`.
- A five-line summary of the change, for the reviewers.

## 3. Five reviewers, in parallel

One `Agent` each (`model: sonnet`), all in one message. Each gets the summary, the diff, the rule-file
paths, the read-only rule and its lens, and returns issues as `path:start-end — what goes wrong —
evidence`. The changed lines only, unless the change breaks something outside them.

1. **Written rules.** Breaches of what the rule files or Workflow → PR contract state. Quote the
   rule; a rule nobody wrote down is not a rule.
2. **Bugs.** Large ones: wrong results, crashes, the edges (nil, empty, zero, concurrency, time zones,
   encodings, partial failure), security (input reaching SQL, a shell, a path or HTML; authorisation
   on every new entry point), a test that cannot fail or does not test its name. Read the callers and
   the other half of every contract. Skip nitpicks.
3. **History.** `git log` and `git blame` of the modified code: a reverted fix coming back, an
   invariant a past commit fenced, a pattern the code deliberately moved away from.
4. **Earlier PRs.** Merged PRs that touched these files (`gh pr list --state merged --search <path>`,
   their `gh api repos/<o>/<r>/pulls/<n>/comments`): review comments that apply here too.
5. **Code comments.** Guidance in the modified files' comments ("keep in sync with", "must run
   before", "never call from") that the change ignores.

## 4. Score each issue independently

Merge duplicates, then one `Agent` per issue (`model: haiku`), in parallel, never the reviewer that
found it. It gets the PR, the issue and the rule files, and returns 0–100:

- **0** — a false positive, does not survive scrutiny, or pre-existing.
- **25** — might be real; or a style point no rule file names.
- **50** — real, but minor relative to the PR.
- **80** — double-checked and very likely real; it changes behaviour, or a rule file names it.
- **100** — certain, and it will happen in practice; the evidence confirms it.

A written-rule issue scores 0 unless the scorer quotes the rule text that names it.

## 5. Filter

Drop every issue under 80, and any issue that is:

- pre-existing, or on lines the PR did not change (unless the change is what breaks it);
- reported by CI, a linter or a type checker anyway;
- general quality no rule file asks for, or a nit a senior engineer would not raise;
- deliberately silenced in the code (an ignore comment), or an intended change in behaviour;
- already raised by the review bot.

## 6. Output

Links pin the head: `https://github.com/<owner>/<repo>/blob/<full headRefOid>/<path>#L<a>-L<b>`,
with one line of context on either side.

**Default: print, post nothing.**

```markdown
## Files requiring manual review
| File | Reason (a security boundary, a migration, a concurrency path — even with no issue) |

## Issues
1. `path:line` — what goes wrong (rule: "<quote>" | bug: <cause>) — <link>

## Verdict
Request Changes (any issue) | Approve — one line
```

**`post`.** Re-run step 1's call first: closed, now a draft, or a new head → stop and say so. Then
exactly one comment, `gh pr comment <PR> --body-file - <<'EOF'`:

```markdown
### Code review

Found N issues:

1. <what goes wrong> (`<rule file>` says "<quote>" | bug: <cause>)

<link>

Reviewed at <full headRefOid>
```

No issues: `No issues found. Checked for bugs and the repository's written rules.` in place of the
list. No emojis, no attribution footer, never a second comment.
