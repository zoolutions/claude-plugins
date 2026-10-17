---
name: controllers
description: Rails controllers, routes, strong params and responses, with tenant scoping and authorization on every action. Use when adding or changing an endpoint, a route, or an action's params, authorization or response.
argument-hint: "controller, route or action task"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# Controllers: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`: **Tenant**, **Authorization**, **Views**,
**Interactivity**, **Specs**. A missing label means "none".

## Every action, in order

1. **Authenticate.** The base controller's `before_action` stays on. Skipping it needs a comment
   saying why the endpoint is public.
2. **Load through the tenant root** (Workflow → Tenant): `current_tenant.things.find(params[:id])`.
   Never `Thing.find(params[:id])`: it lets a user of one tenant read another's record.
3. **Authorize** with the library in Workflow → Authorization: member actions on the record, `index`
   on the scoped collection, `new`/`create` on the built record. Compare actions: if `index` scopes,
   `show`, `update` and `destroy` must scope the same way.
4. **Strong params.** Explicit `permit(...)`, never `permit!`. Never permit the tenant FK, owner,
   role, status, balance or any flag the user may not set; set those server-side.
5. **Delegate.** More than a few lines of business logic → a service (/rails-app:services); the action
   calls it and branches on its result.
6. **Render** per Workflow → Views. Phlex: `render Views::Things::Show.new(thing:)` with keyword
   args; never instance variables leaking into the view, never `render "things/show"`. When Workflow
   → Views names a native-view resolver, wrap the class with it.
7. **Background** anything slow (HTTP calls, mail, file processing, more than ~500 ms) as a job with
   IDs (/rails-app:jobs).

## Responses

- Failed create/update: re-render with `status: :unprocessable_entity` (Turbo ignores a 200 form
  response). Successful write: redirect; after `destroy`, `redirect_to …, status: :see_other`.
- Partial updates follow Workflow → Interactivity. With phlex-reactive the component's `action`
  answers (`reply.morph`), not a new `respond_to … format.turbo_stream`; existing Turbo Stream code
  is maintained, not extended (/rails-app:stimulus).
- JSON: an explicit serializer or `as_json(only: …)`; `render json: record` leaks every column.
- Errors: no `rescue => e` that renders `e.message` to the user.

## Routes

- `resources … only:`. A custom verb becomes a nested resource (`Things::ArchivesController#create`)
  rather than a member action, when it has its own authorization rule.
- A catch-all route goes last and must not shadow engine routes (e.g. `POST /reactive/actions`, health
  checks). Run `bin/rails routes -g <name>` after editing.
- Webhook endpoints verify the signature before reading the payload (/rails-app:security).

## Never

| Wrong | Right |
|---|---|
| `Thing.find(params[:id])` | `current_tenant.things.find(params[:id])` |
| an action without an authorization call | the library's call per Workflow → Authorization |
| `params.permit!` / permitting `role`, `*_id` of the tenant | explicit `permit` of user-editable fields |
| `render "things/show"`, ivars into a Phlex view | `render Views::Things::Show.new(thing:)` |
| 40 lines of logic in `create` | a service object |

## Spec

Request specs (/rails-app:tests) for what a browser flow does not prove: each role allowed and denied,
a record of another tenant answers 404, a forbidden param is ignored. The happy path belongs in the
feature's system spec.

Done when the spec is green and Workflow → Verify passes.
