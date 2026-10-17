---
name: mailers
description: Email and multi-channel notifications — mailers, notifier classes, previews and delivery. Use when adding or changing an email, a notification, its channels or its recipients.
argument-hint: "email, notification or channel task"
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# Mailers and notifications: $ARGUMENTS

**Read the repository first.** `AGENTS.md` → `## Workflow`: **Notifications** (notifier library and
directory, preview path, mail layout), **I18n**, **Jobs**.

## Delivery

- `deliver_later`, never `deliver_now` in a request or inside a transaction (enqueue after commit).
- Arguments are records or IDs that serialize (GlobalID); never an unsaved record or a large hash.
- Render in the recipient's locale: `I18n.with_locale(recipient.locale) { mail(...) }`, not the
  sender's request locale.
- Multi-channel: when Workflow → Notifications names a notifier library, one notifier class per event
  with its channels (`deliver_by :email`, chat, push) and their conditions; triggered with
  `.with(...).deliver_later`. No ad-hoc HTTP to a chat service from a model or controller.
- Recipients are resolved from the tenant (Workflow → Tenant); a notification never reaches a user of
  another tenant.

## Content

- Subject and every line of copy through `t("<mailer>.<method>.<key>")` (/rails-app:i18n).
- Links: full URLs from the mailer's `default_url_options` for the right host; links that sign in or
  act carry `signed_id(expires_in:)` or `generates_token_for` tokens, never a permanent ID.
- Marketing or digest mail: an unsubscribe link and a `List-Unsubscribe` header.
- No secrets, internal IDs or other users' data in the body.

## Every mailer method has

- A preview (path per Workflow → Notifications) that builds its own data, so it renders on an empty
  database.
- A mailer spec: recipient, subject, a body fragment, the locale; and for a notifier, which channels
  fire under which condition.
- Callers specced with `have_enqueued_mail(ThingMailer, :method)` (or the notifier's matcher).

## Done when

- The preview renders; an email change carries before/after screenshots per Workflow → PR contract.
- Specs are green and Workflow → Verify passes.
