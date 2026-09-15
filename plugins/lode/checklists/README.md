# Shared reviewer checklists

These are the failure classes that produced accepted review findings in **more than one** repository. They are what the gate agents read alongside the repo's own `lode/review/`.

A repo-specific rule stays in that repo's `lode/review/`. A rule graduates here when `/lode:learn` finds the same class in a second repo, or when a maintainer can name two repos it applies to. Each entry says what goes wrong, the input that shows it, and the safe direction. Keep entries short; the agents read every line.

Each gate agent reads only the checklist for its lens (`tests.md`, `docs-claims.md`, `parsers.md`, `error-handling.md` + `files-and-io.md`; at critical, `state-and-concurrency.md` on the second correctness pass). `gate-rules` reads the repository's own rules, not these files. At `light`, claims still runs when the delta has prose — a lode or docs PR is what that agent is for. A class that is only found by constructing a failing input is correctness's work, and correctness does not run on a prose-only delta. A repo that needs such a class caught on a path raises that path's tier in its Rigor table.
