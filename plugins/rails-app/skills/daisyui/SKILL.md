---
name: daisyui
description: How a component's look is declared in an app that uses the daisyui gem with Phlex — modifiers, the `variants` block (defaults, compounds, hover/open/focus states, slots), Tailwind sources and introspection. Use when writing or changing a component's look, adding a modifier, a hover/open/focus state, or the classes of one of its parts.
argument-hint: "component, modifier, state or look to change"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# DaisyUI looks: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`: **UI kit** (the wrappers to call and the
base class to subclass), **Views** (where components live), and any line on styling or generated
Tailwind sources (the generated file's path, the stylesheet that imports it, the lint exclusion). Those
facts override the defaults below. Everything here needs a gem version with `variants`
(2.2.0, unreleased: the gem's `main` until it ships; check `DaisyUI::Base.respond_to?(:variants)`).

## Decision ladder

Take the first rung that expresses the design.

1. **An existing modifier.** `Button(:ghost, :sm)`. Read the component's schema first (below).
2. **A `variants` declaration on the app's wrapper.** A new member, default, compound or state: the look
   lives in one class, as data, and every call site gets it.
3. **A Tailwind utility at the call site.** `Button(:primary, class: "w-full")` for a one-off layout
   need, never a look the component should own.
4. **CSS, only to extend the framework** (a token, `@utility`, `@custom-variant`), and only as the
   repository's own styling rule allows; it usually needs a human's approval. Never per-feature CSS,
   never `!important`.

## The `variants` block

```ruby
class Tile < DaisyUI::Button           # or the app's wrapper base
  variants do
    base "font-medium"                                    # every instance, after the inherited base
    variant :tone, calm: "btn-ghost", loud: "btn-primary" # alternatives (one ClassMerge group)
    flag :wide, "btn-wide"                                # on/off; `flag :name` alone = no class
    default :tone, :calm                                  # when the caller names no :tone
    compound tone: :loud, wide: true, class: "uppercase"
    state :hover, "hover"                                 # name a Tailwind variant once
    on :hover, tone: :calm, class: "[--btn-bg:transparent]"
    slot :menu, "mt-2"                                    # a part; see slot_classes below
  end
end

Tile()              # btn font-medium btn-ghost hover:[--btn-bg:transparent]
Tile(:loud, :wide)  # btn font-medium btn-primary btn-wide uppercase
```

| Declaration | Meaning |
|---|---|
| `base "…"` | Classes every instance gets. |
| `variant :group, member: "…"` | Alternatives; re-declaring an inherited member overrides it. A Hash value is per slot. |
| `flag :name, "…"` | On/off modifier. |
| `default :group, :member` | Used when the caller names none of the group. |
| `compound(**match, class:, set: {})` | Classes (and members for empty groups) when `match` holds. |
| `state :name, "variant"` | Names `hover`, `focus-visible`, `[.dropdown[open]>&]`, … |
| `on(states, **match, class:)` | Like `compound`, written once per state. |
| `slot :name, "…"` | A part. In the component: `slot_classes(:menu, options)` returns its classes (given `class:` last); `slot_options(:menu, options)` returns `options` carrying them. |

A `match` value holds when:

| Value | Holds when |
|---|---|
| `:member` | that member is selected (given, defaulted or set) |
| `[:a, :b]` | any is selected; a `nil` in the list means "or none" |
| `nil` / `false` | no member of the group is selected |
| `true` | any member of the group is selected |
| `true` / `false` (flag) | the flag is on / off |

A typo (unknown group, member, flag, state or slot) raises `ArgumentError` at class load.

## Render order pitfalls

Order: component class, `base`, the caller's modifiers, defaulted and `set:` members, compounds, `on`
rules, `responsive:`, then `class:`. ClassMerge keeps the last of any conflicting group.

- A **default** renders after the caller's modifiers, so a default member beats a caller's modifier
  that sets the same property. Put such a value in `base` instead.
- **Compounds and `on` rules** also land after the caller's modifiers. When one overrides a property
  a modifier sets, leave that modifier out of the match (`layout: [nil, :row]`).
- `on` writes `<state>:<class>`, the state outermost. A rule that needs a child selector first
  (`[&_li]:hover:…`) cannot be an `on` rule; keep it literal in `base`.
- Don't name a group like an inherited one with a different meaning (`Button` already has `shape`:
  your members become alternatives of its `circle` and `square`).
- A state selector with a child combinator puts `>` inside the class attribute; a spec that matches
  HTML with `<a[^>]*…>` breaks. Parse with Nokogiri or `rendered.css(…)`.

## Tailwind sources

Tailwind v4 compiles only literal classes, and an `on` class (`hover:…`) is written nowhere. Generate
the sources and commit them:

```sh
bin/rails "daisyui:tailwind[app/assets/stylesheets/generated/daisyui_app.css]"
# no Rails: bundle exec daisyui-tailwind --app --require ./components.rb -o <file>
```

- `@import` the file from the Tailwind entry. Workflow's path and entry win over this example.
- Add a spec so a changed declaration fails until regenerated:
  `expect(DaisyUI::Tailwind.stale?(path)).to be(false)`.
- Exclude the generated file from the stylesheet linter.
- Regenerate after every change to a `variants` block, and commit the file with it.

## Introspection

Read what a component already offers before declaring anything.

```ruby
Tile.variants.schema        # frozen Hash: base, variants, flags, defaults, compounds, on, states, slots
Tile.variants.literal_classes
```

The gem's MCP server (`bundle exec daisyui-mcp`) has `list_components`, `get_component` and
`search_components`; `get_component` returns the schema too when your gem version has it. Without it,
read the component's source in the gem.

## Anti-patterns

- A class-string constant (`CLASSES = "btn btn-ghost"`) or a `base_class` override instead of `base`.
- A method that reads `modifiers` and picks classes (`modifiers.include?(:loud) ? … : …`): that is a
  `variant`, `flag` or `compound`.
- An interpolated class (`"btn-#{tone}"`, `"hover:#{x}"`): Tailwind cannot see it. Declare each member.
- A raw element with the kit's classes (`button(class: "btn …")`); call the wrapper (/rails-app:views).
- A feature-named CSS selector for something a `state` and `on` express.
- Editing the generated sources file by hand.

## Done when

- A component spec renders each new member, default and compound and asserts the classes.
- The generated sources are regenerated and committed, and the stale spec passes.
- Workflow → Verify passes.
