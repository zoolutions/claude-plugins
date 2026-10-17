---
name: github-review-comments
description: Answer every unresolved review thread on a PR — human or bot (cubic, CodeRabbit) — by fixing what is right and pushing back, with reasons from the code, on what is wrong; then resolve every thread. Use when a PR has open review comments; /flow:github-review-pr runs it as its Phase B.
argument-hint: "PR number (e.g. 123 or #123); empty = the current branch's PR"
model: sonnet
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent, ToolSearch, mcp__cubic__get_pr_issues, mcp__cubic__update_pr_issue_status
---

# Review comments: $ARGUMENTS

Evaluate each comment against the actual code before accepting or rejecting it. Repository facts:
`AGENTS.md` → `## Workflow` (Verify, Review bot).

## Phase 0: The PR

`PR123`, `123`, `#123` → 123. Empty → `gh pr list --author=@me --head="$(git branch --show-current)"
--state=open --json number,title`; one result → use it, else ask (unattended: the caller passes it).
Confirm with `gh pr view <PR> --json title,state,url`.

## Phase 1: Unresolved threads

```bash
gh api graphql -F owner='{owner}' -F repo='{repo}' -F pr=<PR> -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) { pullRequest(number: $pr) {
      reviewThreads(first: 100) { nodes {
        id isResolved path line
        comments(first: 20) { nodes { databaseId body author { login } createdAt } }
      } }
    } }
  }'
```

Keep the unresolved ones (page with `after:` past 100). Skip `dependabot`. **Bot threads are review
threads**: a cubic (`cubic-dev-ai`) or CodeRabbit (`coderabbitai`) thread is treated exactly like a
human's — a bot approves only once every issue it raised is fixed or answered, and a ruleset may
refuse to merge with any thread open.

**cubic MCP, when Workflow → Review bot is cubic.** `ToolSearch`
`select:mcp__cubic__get_pr_issues,mcp__cubic__update_pr_issue_status`. If they load,
`get_pr_issues` (the PR URL as `pullRequest`) gives each open cubic issue's `issueId` (match on `path`
+ `line`); an unresolved cubic thread with no open issue was already triaged — if its replies answer
it, just resolve it. Its `review` block says whether cubic has seen the latest push; if a review is
still running, say the list may be incomplete.

**CodeRabbit** also lists findings in its latest review body ("Nitpick comments", "Outside diff
range"), with no thread. They are findings too: fix or answer them in one PR comment.

No unresolved thread and no body findings → report it and stop.

## Phase 2: Categorise

Read the file and line first; check the claim against this codebase, what it would break, the
existing patterns and AGENTS.md (project rules override reviewer preference).

| Category | Action |
|---|---|
| Valid bug / test gap / consistency issue | Fix it |
| Wrong for this codebase / conflicts with the architecture / YAGNI | Push back, citing code |
| Unclear | Read the code until it is clear, then one of the above |

Every comment ends fixed or answered in this pass, whatever its severity (P1–P3, docs, nits).
Nothing is deferred to a follow-up; nothing is left to the user to decide.

## Phase 3: Fix

Edit; run the affected specs and Workflow → Verify on the changed files; one commit
(`fix: address review feedback` with a bullet per fix); push. Several comments asking for one change:
fix once, reference it in every reply.

## Phase 4: Reply and resolve

- Fixed: `gh api "repos/{owner}/{repo}/pulls/<PR>/comments/<COMMENT_ID>/replies" --method POST -f 'body=Fixed in <SHA>. <what changed>.'`
- Pushed back: same endpoint, the technical reason, citing code or AGENTS.md.
- cubic with the MCP loaded: record the outcome instead —
  `update_pr_issue_status(issueId, triageStatus, comment)` with `resolved` ("Fixed in <SHA>. …"),
  `false_positive`, `wont_fix` or `intended_behavior` (each with its reason). Cubic reads these before
  it re-reviews; a push-back recorded here is what lets it approve.
- Then resolve every thread the reply did not already resolve:

  ```bash
  gh api graphql -f query='mutation($threadId: ID!) { resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } } }' -f threadId=<THREAD_ID>
  ```

- A general PR comment (not a thread): `gh pr comment <PR> --body '…'`.

Style: no "great point", no thanks; state the fix with its short SHA, or the reason with the code it
rests on; say what would break or which edge case the reviewer missed.

## Phase 5: Verify

Re-run Phase 1's query: zero unresolved. Report fixed / pushed back / resolved counts.

A new round after your push (bots re-review every head) is more work: run this again. A comment that
re-raises something already fixed or answered gets one reply pointing at that commit or answer, and
is resolved — never re-litigated.
