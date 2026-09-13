# Documentation and changelog claims

Accepted findings in importmap-plus, dash, pgbus, docs-kit and phlex-reactive. Prose drifts from code faster than tests do, and reviewers read the prose.

- **A fact lives in one place or in every place.** A flag's scope, a precedence rule ("`--remote` wins over `--vendor`"), a limit ("only named packages, not resolved dependencies") that appears in the CLI reference must also appear in the guide page, the changelog and the upgrading page, or the reader who lands on the other page is misled. `grep` for the subject before finishing.
- **Describe the failure the runtime actually produces.** "Silently binds undefined" when the browser raises a link-time SyntaxError; "the command fails" when it exits 0 with a warning; "returns nil" when it raises. Run it or read the spec.
- **A sentence written before a behaviour change is stale after it.** "`pristine` redownloads it" was true until the pin became remote; nobody re-read the sentence. When a diff changes what happens to an object, grep the docs for every sentence about that object.
- **Changelog entries overclaim.** "Existing pins are never rewritten" when the next `update` converts them. State exactly which commands leave a thing alone and which do not.
- **Transcripts are real.** Output shown in docs matches the exact string the code prints, including paths and punctuation, or it says it does not and why.
- **Grammar sections enumerate everything.** A new reason, status, option or provenance token added in prose must also be added to the list that claims to be complete.
- **Wording that implies a guarantee** ("always", "atomic", "never lost") is a claim about code; find the line that makes it true.
- **Broken grammar in a doc** is a P3 finding, not a nit: a sentence that fuses two clauses is read two ways.
- **A "Discrepancies" or "known gaps" section goes stale on the branch that fixes the gap.** Seen in importmap-plus: two lode summaries recorded a CLAUDE.md gap that the same PR closed, so the memory shipped describing a state that no longer existed. Fixed gaps go in the PR body; a document states only what is true of the tree it ships in.
- **Line ranges and counts are computed, not eyeballed.** Seen in importmap-plus: nine citations were off by one to four lines and two counts were wrong, all in files whose other citations were exact, which makes the wrong ones trusted. Derive `def`-to-`end` ranges and test counts with a script and paste the output.
