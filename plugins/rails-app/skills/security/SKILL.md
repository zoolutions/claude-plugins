---
name: security
description: Security review of Rails code — tenant isolation, authorization on every entry point, injection, XSS, mass assignment, dangerous dispatch, deserialization, webhooks, uploads and config. Use for a security review of a diff or an area, or whenever code touches user input, authorization, secrets or shell commands.
argument-hint: "diff (default), file, feature or area to review"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent, Skill
model: opus
---

# Security review: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`: **Tenant**, **Authorization**, **Views**,
**Verify** (the static scanners). Empty argument: review `git diff origin/main...HEAD`.

For every touched entry point ask: whose data is this, who may do this, what does the user control,
which dangerous API does it reach, and what happens on failure.

## 1. Entry points and tenant isolation

Entry points: controller actions, reactive actions, API endpoints, webhooks, jobs, mailbox handlers,
tool handlers. Each one authenticates (or says in a comment why it is public), loads through the
tenant root (Workflow → Tenant) and authorizes with Workflow → Authorization.

- IDOR: `Model.find(params[:id])` or `find_by(id:)` without the tenant root. Compare every action of
  a controller: one unscoped action is enough.
- Authorization by allowlist (roles that may), never by denylist (roles that may not).
- Jobs and services receive the tenant explicitly; a cross-tenant query in a job is the same leak.
- Responses, exports, search results and broadcasts carry only the current tenant's rows.

## 2. Checklist

| Category | Flag | Safe |
|---|---|---|
| SQL injection | interpolation in `where`, `order`, `group`, `having`, `pluck`, `select`, `joins`, `from`, `lock`, `find_by_sql`, `execute`; `exists?(params[:x])`; array literals built by string (`"{#{ids.join(',')}}"`) | hash conditions, `?` placeholders, `ARRAY[?]::text[]`, allowlisted sort columns |
| XSS | `html_safe`/`raw`/`unsafe_raw`/`<%==` on user data; `link_to` with a user URL (`javascript:` is a valid scheme); `simple_format(...).html_safe` | auto-escaping; `sanitize` with an allowlist; URL validated to `http`/`https` on the model |
| Mass assignment | `permit!`; permitting role, owner, tenant FK, status, balance, verified flags | explicit `permit` of user-editable fields |
| Dangerous dispatch | `send`/`public_send`/`constantize`/`safe_constantize` on params or stored user data | allowlist constant, then dispatch |
| Code / deserialization | `eval`; `Marshal.load` of anything external; `YAML.load` on untrusted input | JSON; `YAML.safe_load` |
| Command injection | backticks, `system("… #{x}")`, `%x{}`, `IO.popen`, `Open3` with interpolation | array form: `system("cmd", arg1, arg2)` |
| Files | no type/size check; user filename in a path (`../`); public storage without access control | content-type + size validation, generated names, signed or authorized URLs |
| SSRF | fetching a user-supplied URL server-side | allowlisted hosts, or don't fetch |
| Webhooks | no signature check; non-constant-time compare; no replay window | HMAC over `"#{timestamp}.#{raw_body}"`, `ActiveSupport::SecurityUtils.secure_compare`, reject timestamps older than ~5 minutes, then enqueue |
| Sessions | no `reset_session` on login/logout; secrets in the session; no expiry | rotate on login, expire, store IDs only |
| Tokens in URLs | guessable or permanent | `signed_id(expires_in:)`, `generates_token_for` |
| Config | `force_ssl` off, `consider_all_requests_local` in production, `skip_forgery_protection` without a reason, wide `config.hosts`, missing `filter_parameters` (password, token, secret, otp, api_key) | the safe default, with a comment for any exception |
| Errors | `e.message`, SQL or stack traces in a response; secrets in logs | generic message, details to the APM |
| Dependencies | known CVEs | the audit commands in Workflow → Verify |

## 3. Run the scanners

Workflow → Verify's security commands (brakeman, and the dependency audits it lists). A new brakeman
ignore entry needs a note explaining why the finding is a false positive.

## Output

```
### [CRITICAL|HIGH|MEDIUM|LOW] <title>
File: path:line · Category: <category>
Why: <what an attacker does with it>
Fix: <the corrected code>
```

End with a verdict: `BLOCK` (any CRITICAL/HIGH), `FIX BEFORE MERGE`, or `CLEAN`. When asked to fix,
write a failing spec for each finding first (a cross-tenant 404, a denied role, an escaped payload),
then the fix.
