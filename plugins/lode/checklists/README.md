# Shared reviewer checklists

These are the failure classes that produced accepted review findings in **more than one** repository. They are what the gate agents read alongside the repo's own `lode/review/`.

A repo-specific rule stays in that repo's `lode/review/`. A rule graduates here when `/lode:learn` finds the same class in a second repo, or when a maintainer can name two repos it applies to. Each entry says what goes wrong, the input that shows it, and the safe direction. Keep entries short; the agents read every line.

At the `light` rigor tier only `gate-tests` and `gate-rules` run (plus `gate-parser` when the diff parses), so a class that must be caught in a light repo belongs in `tests.md` or `parsers.md`, or in that repo's own `lode/review/`; the correctness and claims agents, and the checklists only they read, do not run there.
