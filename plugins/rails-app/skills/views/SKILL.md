---
name: views
description: Pages and reusable components — Phlex views, the app's UI-kit wrappers, forms, streamable components and native variants. Use when building or changing a page, a component, a form or anything a user sees.
argument-hint: "page, component, form or UI task"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# Views: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`: **Views** (engine, base classes, where
pages and components live, streamable concern, native variant), **UI kit** (wrappers, forms,
forbidden raw forms), **Interactivity**, **I18n**. Phlex is the default; an app whose Workflow →
Views names another engine (Slim, ERB, Liquid) keeps it, and every rule below that is not Phlex syntax
still holds.

## Structure

- Pages: `Views::<Dir>::<Action>` in `app/views/<dir>/<action>.rb`, inheriting the page base.
  Components: under `app/components/`, inheriting the component base. Never a new ERB or HAML file in
  a Phlex app.
- Everything the view prints comes in as keyword args. No queries in a view; a component iterating a
  collection means the controller preloads it (/rails-app:database).
- Reuse before writing: search `app/components/` for the wrapper or component first, and read its
  source before falling back to a Rails primitive.

## UI kit

- Use the wrappers Workflow → UI kit names, never the raw element with the kit's classes
  (`button(class: "btn …")`, `link_to … class: "btn"`) and never the underlying library's classes
  directly (e.g. `DaisyUI::Card.new`).
- Wrapper modifiers are positional symbols: `Button(:primary, :sm)`, never `Button(primary: true)`.
- Forms use the form API Workflow → UI kit names (e.g. a `Form(model:)` component and its field
  helpers, or `form_for`), never a form builder it forbids (e.g. `form_with`) or a second one beside it. Show
  the record's errors with the kit's error component.
- Classes: `class_names("base", "variant" => condition)` or Phlex `mix`; never `.join(" ")` or a
  ternary inside a class array. Keep class strings literal (`"btn-primary"`, not `"btn-#{kind}"`):
  the CSS build scans the source and drops classes it cannot see.

## Phlex traps (silent, no error)

- `plain` takes a String: `plain(count.to_s)`.
- A bare `Date`/`Time`/`BigDecimal` in an element block renders nothing: `td { l(date) }`.
- A block's return value is used only when the block emitted nothing. A string-returning helper (an
  unwrapped Rails form builder, `content_tag`) inside a block that also emits is dropped. Use the
  Phlex builder that pushes into the buffer.
- Helpers: call them as the base class registers them; add a registration instead of reaching through
  `helpers.`. `raw` needs an `html_safe` string; `unsafe_raw` only for markup you built, never user
  content.
- A model named like a component in an included namespace needs a leading `::` (`::Thing.where…`).

## Updates and interactivity

- A component that a stream, a morph or a broadcast replaces has a stable `id` method
  (`dom_id(record, :card)`), renders that `id:` on its root, and includes the streamable concern
  Workflow → Views names.
- Interactive behaviour follows Workflow → Interactivity (/rails-app:stimulus): phlex-reactive client
  ops and actions first. No inline `onclick` (CSP).
- Native variant (when Workflow → Views names one): a separate native view class, never
  `turbo_native_app?` branches in a web view; never `data-turbo="false"` (it bypasses the native
  navigator), use `data-turbo-frame="_top"` to leave a frame.

## Text

Every user-visible string is `t("fully.qualified.key")` (/rails-app:i18n), including `title`,
`aria-label`, placeholders and confirm texts.

## Done when

- A component spec renders it with real-ish data; the page is covered by the feature's system spec.
- A UI change carries before/after screenshots per Workflow → PR contract.
- Workflow → Verify passes. A custom cop that flags a raw element is fixed with the wrapper it names,
  not disabled.
