# rails-app

Layer specialists for Rails applications. Enable it beside `flow`; it costs nothing until a skill
is invoked. Every skill reads the app's facts from `AGENTS.md` → `## Workflow` (the generic labels
from `flow`, plus the Rails labels below), so nothing app-specific lives here.

```bash
claude plugin install rails-app@zoolutions
```

`phlex-reactive-debugging` is not here: the phlex-reactive gem generates it into each app
(`rails g phlex:reactive:claude`) and keeps it current.

| Skill | For |
|---|---|
| `/rails-app:architect` | A feature across several layers: layer order, delegation, cross-cutting checklist, validator before the PR |
| `/rails-app:models` | Tables, columns, indexes, associations, validations; PostgreSQL migration safety and generated migration versions |
| `/rails-app:database` | N+1s, indexes, EXPLAIN, batching, bulk writes; `diff` audits the branch for N+1 patterns |
| `/rails-app:controllers` | Endpoints, routes, strong params, responses; tenant scoping and authorization on every action |
| `/rails-app:views` | Pages and components (Phlex by default), UI-kit wrappers, forms, streamable components, native variants, Phlex traps |
| `/rails-app:daisyui` | A component's look with the daisyui gem: modifier, `variants` (defaults, compounds, hover/open states, slots), Tailwind sources, schema and MCP introspection |
| `/rails-app:stimulus` | Interactivity: phlex-reactive first, the operator-confirmed Stimulus/Turbo Stream exception, maintaining existing controllers |
| `/rails-app:services` | Service objects, transactions, result shape, external API clients and webhooks intake |
| `/rails-app:jobs` | Idempotent tenant-aware jobs, bounded retries, recurring schedules, removing a job class safely |
| `/rails-app:security` | Security review: tenant isolation, authorization at every entry point, injection, XSS, dispatch, webhooks, config |
| `/rails-app:i18n` | Fully qualified keys, no hardcoded strings, translate/normalize/validate loop |
| `/rails-app:mailers` | Mailers, notifiers, previews, locale and delivery |
| `/rails-app:tests` | Spec type choice (system first for browser behaviour), tenant factory chains, cross-tenant examples |
| `/rails-app:appsignal-triage` | Open AppSignal incidents → one deduped GitHub issue per error class |
| `/rails-app:appsignal-debug` | A production error → root cause → fix → PR, handed to `/flow:finish-prs` |

## `## Workflow` lines a Rails app adds

Add these to the generic `## Workflow` section (same rules: one fact per line, true of the tree, a
missing label means "none"). Each skill names the labels it reads.

```markdown
- **Specs:** … (generic line) + sign-in `<helper>`; host `<helper | none>`; wait after reactive `<helper | none>`; agent may run specs: <yes | no — print the command>
- **Tenant:** root `<current_x>`; owned tables carry `<x>_id` (composite indexes lead with it); factory chain `<a> → <b> → <c>`
- **Authorization:** <ActionPolicy | CanCanCan | before_action guards> — member `<call>`, collection `<call>`, reactive actions `<call>`
- **Views:** <Phlex | Slim | ERB>; pages `<base>` in `<dir>`, components `<base>` in `<dir>`; streamable concern `<name>`; native variant `<resolver + dir | none>`
- **UI kit:** <DaisyUI | Bootstrap N> through `<wrappers>`; forms `<Form(model:) | form_for>`; never `<forbidden forms>`
- **Interactivity:** <phlex-reactive first; new Stimulus/Turbo Stream needs operator confirmation | Stimulus | legacy JS>
- **Jobs:** <pgbus | Sidekiq | both> in `<dirs>`; recurring `<schedule file>`
- **Migrations:** safety gem `<name | none>`; version check `<command or cop>`
- **N+1:** `<prosopite | bullet | none>` in specs
- **Services:** `<base>.call(...)`; returns <Success/Failure | raises | value>
- **I18n:** locales `<source> → <others>`; translate `<cmd>`; sync `<cmd | none>`; validate `<cmd>`; money/dates `<formatter>`
- **Notifications:** <noticed in `app/notifiers` | ActionMailer only>; previews `<path>`
- **APM:** AppSignal app `<name>`, CLI org `<org>`; environments `<env>=<app id>` …; labels `<triage label>`, `appsignal:<env>`; production data locally `<cmd | none>`
```

The interactivity rule, the tenant rule and the migration-version rule used to live in
`.claude/rules/`. Plugins cannot ship always-loaded rules, so the one-line form of each belongs in
these `## Workflow` lines; the detail is in the skills.
