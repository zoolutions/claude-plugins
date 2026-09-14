# Parsers, regexes and scanners

Every one of these has produced an accepted finding in at least two repositories: JavaScript module inspection, pin lines, Dockerfile analysis, translation keys, SQL identifiers.

- **Quoting variants.** A construct can appear in single quotes, double quotes, a template literal, or with escaped quotes. A regex that lists `["']` misses backticks; a `.wasm` URL in a template literal was vendored and 404ed.
- **Comments are not code, strings are not comments.** A `// export default` inside a comment must not classify a file as ESM. A `/*` inside a string literal must not start a comment that swallows a real import. Match strings first and keep them whole, then strip comments, then scan. Never do it in the other order.
- **Regex literals contain quotes.** `/["']/` is not a string start. Treat `/` after `=`, `(`, `,`, `:`, `[`, `!`, `&`, `|`, `?`, `{`, `}`, `;`, `throw`, `return` and a control-statement `)` as a possible regex start, and allow whitespace in between.
- **Qualified and prefixed names.** `new window.Worker(` and `new self.Worker(` are still Worker constructors; `WorkerPool` and `MyWorker.Factory` are not. `exports.foo =`, `exports["default"] =` and `define(` are all non-ESM markers, not just `module.exports`.
- **Boundaries that are punctuation.** `\b` fails after `g++`; use `(?=\s|$)`. A prefix match on `SHA` must not match `SHA_LONG`; require the next character to be `}` or non-word.
- **`host:port` is part of the name.** In an image or URL reference, only the last path segment carries a tag or version; a colon before a slash is a port.
- **`./` prefixes and `..`** in path patterns must be normalised before matching, or top-level entries are never matched.
- **Unterminated input.** A heredoc with no delimiter, a string with no closing quote, a block comment with no `*/`: the scanner must stop consuming at the end of the construct's plausible scope, not eat the rest of the file. A quoted token that merely resembles an opener (`'<<EOF'`) must not open anything.
- **Concatenation is not a literal.** `import("chunks/" + name)` is computed, not static; check that the whole argument is one literal, not that the first character is a quote. Move optional whitespace *inside* the lookahead, or `\s*` backtracks to zero and the lookahead reads the space.
- **Multiple occurrences on one line** and a construct at the very start or end of the text are separate rows in the grammar table.
- **Case.** Dockerfile instructions, HTTP headers and HTML tags are case-insensitive; compare on a normalised form.
- **Safe failure direction, written down.** Decide before writing the regex whether a false positive or a false negative is the harmless one, state it in a comment above the regex, and make every ambiguous branch fall that way. For a scanner that decides whether to delete text, "keep when unsure" is the only safe direction; deletion must happen on exactly one branch.
- **One test per grammar row.** A row the code handles today but no test pins will be broken by the next edit.
