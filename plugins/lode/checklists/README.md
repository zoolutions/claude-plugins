# Shared reviewer checklists

These are the failure classes that produced accepted review findings in **more than one** repository. They are what the gate agents read alongside the repo's own `lode/review/`.

A repo-specific rule stays in that repo's `lode/review/`. A rule graduates here when `/lode:learn` finds the same class in a second repo, or when a maintainer can name two repos it applies to. Each entry says what goes wrong, the input that shows it, and the safe direction. Keep entries short; the agents read every line.

At the `light` rigor tier only `gate-tests` and `gate-rules` run (plus `gate-parser` when the diff parses). `gate-rules` still reads every checklist, but as a rule audit of the diff; a class that is only found by constructing a failing input or by tracing a prose claim to code is the correctness and claims agents' work, and those do not run at `light`. A repo that needs such a class caught on a path raises that path's tier in its Rigor table.
