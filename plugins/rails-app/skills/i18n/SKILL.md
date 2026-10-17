---
name: i18n
description: Translations and localization — fully qualified keys, no hardcoded strings, locale files kept normalized and validated. Use when adding user-visible text, extracting hardcoded strings, or fixing a failing translation check.
argument-hint: "view, feature, key or translation task"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# I18n: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow` → **I18n** names the locales, the source
locale, the translate/sync command, the validate command and the money/date formatter.

## Keys

- Fully qualified, always: `t("things.show.title")`, never `t(".title")` or `t("title")`. Relative
  keys are ambiguous across views and components and break translation-state tracking.
- Layout: pages `<controller>.<action>.<key>`, components `components.<name>.<key>`, mailers
  `<mailer>.<method>.<key>`, shared words `common.<key>`, enums `enums.<model>.<attr>.<value>`.
- Search before adding: `grep -rn "<text or key>" config/locales` (or `bundle exec i18n-tasks find`).
  Reuse `common.*` instead of a duplicate.

## What must be translated

- Every user-visible string: views, components, flash, mailer subjects and bodies, validation
  messages, `title`, `aria-label`, placeholders, confirm dialogs, PDF and export headers.
- May stay literal: log lines, exception messages for developers, internal DSL identifiers.

## Writing values

- Interpolate (`"Hello, %{name}"`), never concatenate translated fragments: word order differs.
- Plurals: `one`/`other` (plus `zero` when the copy differs) and whatever the locale needs.
- HTML only in keys ending `_html`; interpolated values stay escaped.
- Dates, numbers and money through `l()` and the formatter Workflow → I18n names, never
  `strftime` with a hardcoded format or a hand-built currency string.

## After editing locale files

1. Edit the source locale only.
2. Run Workflow → I18n's translate command for the other locales (or its sync command when only the
   source text changed and the other locales are still right).
3. `bundle exec i18n-tasks normalize -p`; `bundle exec i18n-tasks unused` for keys you orphaned.
4. Workflow → I18n's validate command must pass before commit.

Never silence one validator violation with the tool's accept-everything command (it accepts every
hand-edited key at once): run the exact scoped command the validator prints. Workflow → I18n names the
tool and any such command.
## Never

| Wrong | Right |
|---|---|
| `t(".title")` | `t("things.show.title")` |
| `"Save changes"` in a view | `t("common.save")` |
| `t("a") + " " + t("b")` | one key with `%{}` |
| editing a generated locale by hand | the source locale + the translate command |
| a duplicate key under a new name | the existing `common.*` key |

Done when no hardcoded string remains in the touched files and Workflow → I18n's validate command
and Workflow → Verify pass.
