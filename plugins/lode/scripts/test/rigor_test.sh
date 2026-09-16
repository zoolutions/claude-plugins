#!/usr/bin/env bash
# Tests for scripts/rigor.sh. Plain bash, no framework. Run: bash plugins/lode/scripts/test/rigor_test.sh
# Each case builds a throwaway git repo, writes (or omits) lode/workflow.md, and asserts the
# one-word tier on stdout. Exit 1 if any case fails.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # the user's config (fsmonitor, maintenance) must not leak in
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIGOR="$HERE/../rigor.sh"
TMP="$(mktemp -d)"; trap 'cd / && rm -rf "$TMP"' EXIT
fail=0; n=0

# make_repo <name> [profile-body]; leaves the repo path in $REPO, on branch main with one commit
make_repo() {
  REPO="$TMP/$1"; mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.name=t -c user.email=t@t config commit.gpgsign false
  if [[ $# -gt 1 ]]; then mkdir -p "$REPO/lode"; printf '%s\n' "$2" > "$REPO/lode/workflow.md"; fi
  echo base > "$REPO/README.md"
  git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm base
}

# tier_for_files <repo> <file>... — feeds paths on stdin
tier_for_files() {
  local repo="$1"; shift
  ( cd "$repo" && printf '%s\n' "$@" | bash "$RIGOR" --files 2>/dev/null )
}

check() { # check <case> <expected> <actual>
  n=$((n+1))
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

PROFILE_LIGHT='# Workflow profile

## Commands
none

## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/services/**` | critical |
| `lib/engine/*.rb` | standard |
| `config/routes.rb` | critical |
| `docs/user guide/**` | standard |
| `db/migrate/` | critical |
| `lib/a.b.rb` | critical |

## Verification
none'

# 1. no profile
make_repo noprofile
check "no profile -> standard" standard "$(tier_for_files "$REPO" app/x.rb)"
err="$(cd "$REPO" && printf 'app/x.rb\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"
check "no profile says why on stderr" "yes" "$([[ "$err" == *"lode/workflow.md"* ]] && echo yes || echo no)"

# 2. profile without heading
make_repo noheading '# Workflow profile

## Commands
none'
check "no Rigor heading -> standard" standard "$(tier_for_files "$REPO" app/x.rb)"

# 3. heading, default only, empty table
make_repo emptytable '## Rigor

- Default: light

| Paths | Tier |
|---|---|'
check "empty table -> default" light "$(tier_for_files "$REPO" app/services/x.rb)"

# 4. bad default word
make_repo baddefault '## Rigor

- Default: reckless

| Paths | Tier |
|---|---|
| `app/**` | light |'
check "unknown default -> standard" standard "$(tier_for_files "$REPO" README.md)"
check "unknown default, matching row still applies" light "$(tier_for_files "$REPO" app/x.rb)"

# 5. default in backticks
make_repo tickdefault '## Rigor

- Default: `critical`'
check "default in backticks" critical "$(tier_for_files "$REPO" README.md)"

# 6-12. the light profile with rules
make_repo rules "$PROFILE_LIGHT"
check "no matching row -> default"            light    "$(tier_for_files "$REPO" README.md)"
check "critical path in light repo -> critical" critical "$(tier_for_files "$REPO" app/services/ledger/post.rb app/views/x.rb)"
check "two files, highest wins"               critical "$(tier_for_files "$REPO" lib/engine/a.rb config/routes.rb)"
check "** matches nested"                     critical "$(tier_for_files "$REPO" app/services/a/b/c.rb)"
check "*.rb glob"                             standard "$(tier_for_files "$REPO" lib/engine/a.rb)"
check "* spans directories"                  standard "$(tier_for_files "$REPO" lib/engine/sub/a.rb)"
check "exact file"                            critical "$(tier_for_files "$REPO" config/routes.rb)"
check "exact file is not a prefix"            light    "$(tier_for_files "$REPO" config/routes.rb.bak)"
check "path with a space"                     standard "$(tier_for_files "$REPO" "docs/user guide/intro.md")"
check "trailing slash is a directory prefix"  critical "$(tier_for_files "$REPO" db/migrate/001_x.rb)"
check "pattern, not regex: dot is literal"    light    "$(tier_for_files "$REPO" lib/aXb.rb)"
check "empty file list -> default"            light    "$(cd "$REPO" && printf '' | bash "$RIGOR" --files 2>/dev/null)"

# 13. same file, two rows, different tiers -> higher
make_repo tworows '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/**` | standard |
| `app/services/**` | critical |'
check "two rows on one file -> higher" critical "$(tier_for_files "$REPO" app/services/x.rb)"
check "lower row alone"                standard "$(tier_for_files "$REPO" app/views/x.rb)"

make_repo lowers '## Rigor

- Default: standard

| Paths | Tier |
|---|---|
| `docs/` | light |'
check "light row lowers a docs-only diff"      light    "$(tier_for_files "$REPO" docs/a.md docs/b.md)"
check "unmatched file keeps the default"       standard "$(tier_for_files "$REPO" docs/a.md lib/x.rb)"

# 14. a row with an unknown tier is skipped, not fatal
make_repo badrow '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/**` | urgent |
| `lib/**` | critical |'
check "unknown tier row skipped" light    "$(tier_for_files "$REPO" app/x.rb)"
check "valid row after a bad one" critical "$(tier_for_files "$REPO" lib/x.rb)"

# 15. from git: base...HEAD
make_repo gitdiff "$PROFILE_LIGHT"
git -C "$REPO" switch -qc feat
mkdir -p "$REPO/app/services" && echo x > "$REPO/app/services/pay.rb"
git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm feat
check "git diff base...HEAD"        critical "$(cd "$REPO" && bash "$RIGOR" main 2>/dev/null)"
git -C "$REPO" switch -qc empty main
check "git diff with no changes"    light    "$(cd "$REPO" && bash "$RIGOR" main 2>/dev/null)"
check "bad base ref -> standard"    standard "$(cd "$REPO" && bash "$RIGOR" nope 2>/dev/null)"

# 17. round-2 gate findings
# P1: rule patterns must stay literal even when the directory exists on disk (pathname expansion)
make_repo ondisk "$PROFILE_LIGHT"
mkdir -p "$REPO/app/services/ledger" "$REPO/lib/engine/sub" "$REPO/db/migrate"
echo x > "$REPO/app/services/old.rb"; echo x > "$REPO/lib/engine/old.rb"
git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm ondisk   # so the utf8 commit below holds only the non-ASCII file
check "rule stays a pattern when its dir exists"   critical "$(tier_for_files "$REPO" app/services/ledger/post.rb)"
check "rule stays a pattern for a new file"        critical "$(tier_for_files "$REPO" app/services/new.rb)"
check "*.rb rule with existing siblings"           standard "$(tier_for_files "$REPO" lib/engine/new.rb)"
check "trailing-slash rule with existing dir"      critical "$(tier_for_files "$REPO" db/migrate/002_y.rb)"
# P2: git quotes non-ASCII paths unless told not to
git -C "$REPO" switch -qc utf8
echo x > "$REPO/app/services/über.rb"; git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm utf8
check "non-ASCII path from git"                    critical "$(cd "$REPO" && bash "$RIGOR" main 2>/dev/null)"
# P2: tier cells that are not a bare lowercase word
make_repo tiercells '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/**` | Critical |
| `lib/**` | **standard** |
| `docs/**` | `standard` (docs are reviewed) |'
check "capitalised tier cell"                      critical "$(tier_for_files "$REPO" app/x.rb)"
check "bold tier cell"                             standard "$(tier_for_files "$REPO" lib/x.rb)"
check "annotated tier cell"                        standard "$(tier_for_files "$REPO" docs/x.md)"
err="$(cd "$TMP/badrow" && printf 'app/x.rb\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"
check "unknown tier row is reported"               yes "$([[ "$err" == *"urgent"* ]] && echo yes || echo no)"
# P2: ./ and / prefixes on paths and rules
make_repo prefixes '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `/app/**` | critical |
| `./lib/**` | standard |
| `docs` | standard |'
mkdir -p "$REPO/docs"
check "./ on a stdin path"                        critical "$(tier_for_files "$REPO" ./app/x.rb)"
check "/ anchor on a rule"                          critical "$(tier_for_files "$REPO" app/x.rb)"
check "./ on a rule"                               standard "$(tier_for_files "$REPO" lib/x.rb)"
check "rule naming an existing dir is a prefix"    standard "$(tier_for_files "$REPO" docs/x.md)"
# P2: a fenced example inside or before the section is not parsed
make_repo fenced '# profile

## Docs

```
## Rigor
- Default: critical
```

## Rigor

An example of the shape:

```
- Default: critical
| `docs/` | critical |
```

- Default: light

| Paths | Tier |
|---|---|
| `lib/**` | standard |'
check "fenced Default before the heading ignored"  light    "$(tier_for_files "$REPO" README.md)"
check "fenced row inside the section ignored"     light    "$(tier_for_files "$REPO" docs/x.md)"
check "real row after the fence still parsed"     standard "$(tier_for_files "$REPO" lib/x.rb)"
# P3: Default line variants
make_repo bolddefault '## Rigor

  - **Default:** Light'
check "bold, indented, capitalised Default"        light    "$(tier_for_files "$REPO" README.md)"
make_repo ishdefault '## Rigor

- Default: light-ish'
check "Default: light-ish is unknown"              standard "$(tier_for_files "$REPO" README.md)"
make_repo prosedefault '## Rigor

- Default: `critical` (see the table)

| Paths | Tier |
|---|---|
| docs/** | light | why |
'
check "CRLF, prose after Default, 3 cols, no ticks" light   "$(tier_for_files "$REPO" docs/x.md)"
check "CRLF default"                               critical "$(tier_for_files "$REPO" lib/x.rb)"
# P3: the stderr reason names only the file that decided the tier
err="$(cd "$TMP/lowers" && printf 'docs/a.md\nlib/x.rb\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"
check "no stale reason when the default decided"   no "$([[ "$err" == *"docs/a.md"* ]] && echo yes || echo no)"

# 18. three-dot range: a commit on main after the branch point must not count
make_repo threedot "$PROFILE_LIGHT"
git -C "$REPO" switch -qc feat2 && echo x > "$REPO/README.md" && git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm feat2
git -C "$REPO" switch -q main && mkdir -p "$REPO/app/services" && echo x > "$REPO/app/services/pay.rb" && git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm main-moved
git -C "$REPO" switch -q feat2
check "main moving after the branch point is ignored" light "$(cd "$REPO" && bash "$RIGOR" main 2>/dev/null)"
check "no base argument, no origin -> standard"       standard "$(cd "$REPO" && bash "$RIGOR" 2>/dev/null)"
# 19. comma-separated patterns in one cell
make_repo commas '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/services/**`, `config/routes.rb`, | critical |'
check "first pattern of a comma cell"   critical "$(tier_for_files "$REPO" app/services/x.rb)"
check "second pattern of a comma cell"  critical "$(tier_for_files "$REPO" config/routes.rb)"
# 20. every fail-open path says why
err="$(cd "$TMP/noheading" && printf 'x\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "no-heading reason on stderr" yes "$([[ "$err" == *"no ## Rigor"* ]] && echo yes || echo no)"
err="$(cd "$TMP/baddefault" && printf 'x\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "unknown-default reason on stderr" yes "$([[ "$err" == *"reckless"* ]] && echo yes || echo no)"
err="$(cd "$TMP/gitdiff" && bash "$RIGOR" nope 2>&1 >/dev/null)"; check "bad-ref reason on stderr" yes "$([[ "$err" == *"nope"* ]] && echo yes || echo no)"
err="$(cd "$TMP/rules" && printf 'config/routes.rb\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "match reason names file and rule" yes "$([[ "$err" == *"config/routes.rb matches"* ]] && echo yes || echo no)"

# 21. round-3 gate findings
make_repo nomergebase "$PROFILE_LIGHT"
git -C "$REPO" switch -q --orphan orphan && mkdir -p "$REPO/lode" && printf "%s\n" "$PROFILE_LIGHT" > "$REPO/lode/workflow.md" && mkdir -p "$REPO/app/services" && echo x > "$REPO/app/services/pay.rb" && git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm orphan
check "no merge base -> standard"  standard "$(cd "$REPO" && bash "$RIGOR" main 2>/dev/null)"
err="$(cd "$REPO" && bash "$RIGOR" main 2>&1 >/dev/null)"; check "no merge base says why" yes "$([[ "$err" == *"merge base"* ]] && echo yes || echo no)"
make_repo renamed "$PROFILE_LIGHT"
mkdir -p "$REPO/app/services" && echo "a long enough body to be detected as a rename by git" > "$REPO/app/services/pay.rb" && git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm add
git -C "$REPO" switch -qc mv && mkdir -p "$REPO/lib" && git -C "$REPO" mv app/services/pay.rb lib/pay.rb && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm mv
check "rename out of a critical dir counts" critical "$(cd "$REPO" && bash "$RIGOR" main 2>/dev/null)"
make_repo indented '## Rigor

- Default: **standard**
  | Path pattern | Rigor tier |
  |:---|:---:|
  | `docs/` | light |'
check "table nested under the Default bullet"  light    "$(tier_for_files "$REPO" docs/x.md)"
check "bold Default value"                      standard "$(tier_for_files "$REPO" lib/x.rb)"
err="$(cd "$REPO" && printf 'lib/x.rb\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "header and alignment rows make no noise" no "$([[ "$err" == *"unknown tier"* ]] && echo yes || echo no)"
make_repo fence4 '# p

## Docs

````
```
````

## Rigor

- Default: critical'
check "a longer fence is not closed by a shorter one" critical "$(tier_for_files "$REPO" README.md)"
make_repo bareddir "$PROFILE_LIGHT"
mkdir -p "$REPO/app/services"
check "a bare directory on stdin matches its rule" critical "$(tier_for_files "$REPO" app/services)"

# 22. parser round-2 findings
make_repo globstar '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `spec/**/*_spec.rb` | critical |
| `**/*.md` | standard |'
check "**/ matches zero directory levels"      critical "$(tier_for_files "$REPO" spec/foo_spec.rb)"
check "**/ matches nested levels"            critical "$(tier_for_files "$REPO" spec/models/foo_spec.rb)"
check "leading **/ matches the root"          standard "$(tier_for_files "$REPO" README.md)"
check "leading **/ matches nested"            standard "$(tier_for_files "$REPO" docs/a/b.md)"
make_repo htmlcomment '## Rigor

- Default: critical

<!-- | `app/**` | light | -->
<!--
| `lib/**` | light |
-->

| Paths | Tier |
|---|---|
| `docs/` | standard |'
check "single-line HTML comment ignored"      critical "$(tier_for_files "$REPO" app/x.rb)"
check "multi-line HTML comment ignored"       critical "$(tier_for_files "$REPO" lib/x.rb)"
check "row after the comments still parsed"   standard "$(tier_for_files "$REPO" docs/x.md)"
make_repo rootrules '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `/` | standard |
| `app/**` `lib/**` | critical |
| `config/**` | critical, money path |'
check "rule / means everything"               standard "$(tier_for_files "$REPO" README.md)"
err="$(cd "$REPO" && printf 'x\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "space-separated patterns are reported" yes "$([[ "$err" == *"comma"* ]] && echo yes || echo no)"
check "tier annotated after a comma"          critical "$(tier_for_files "$REPO" config/x.rb)"
make_repo quotedpath "$PROFILE_LIGHT"
git -C "$REPO" switch -qc q && mkdir -p "$REPO/app/services" && echo x > "$REPO/app/services/a\"b.rb" && git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm q
check "path with a double quote from git"     critical "$(cd "$REPO" && bash "$RIGOR" main 2>/dev/null)"
make_repo misc '## Rigor ##

- Default: critical.

~~~
| `docs/` | light |
~~~

| Paths | Tier |
| :--- | ---: |
| `<e.g. app/services/ledger/**, config/routes.rb>` | light |
| `a/**`, , `b/**` | light |'
check "Default with a full stop"              critical "$(cd "$REPO" && printf "" | bash "$RIGOR" --files 2>/dev/null)"
check "~~~ fence ignored"                     critical "$(tier_for_files "$REPO" docs/x.md)"
check "template placeholder row is inert"     critical "$(tier_for_files "$REPO" app/services/ledger/x.rb)"
check "empty middle pattern"                  light    "$(tier_for_files "$REPO" b/x.rb)"
make_repo indentedcode '## Rigor

- Default: light

    ```

| Paths | Tier |
|---|---|
| `app/**` | critical |'
check "an indented unclosed fence swallows the rest, with a note" light "$(tier_for_files "$REPO" app/x.rb)"
err="$(cd "$REPO" && printf 'x\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "the indented unclosed fence is reported" yes "$([[ "$err" == *"never closed"* ]] && echo yes || echo no)"
make_repo unclosed '# p

## Docs

```

## Rigor

- Default: critical'
err="$(cd "$REPO" && printf 'x\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "an unclosed fence is reported" yes "$([[ "$err" == *"fence"* ]] && echo yes || echo no)"

# 23. round-3 gate findings
make_repo globmid '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/**/ledger/**` | critical |
| `a/**/b/**/c` | critical |
| `**/routes.rb` | standard |'
check "**/ in the middle, nested"           critical "$(tier_for_files "$REPO" app/services/ledger/post.rb)"
check "**/ in the middle, zero levels"      critical "$(tier_for_files "$REPO" app/ledger/post.rb)"
check "**/ in the middle does not over-match" light   "$(tier_for_files "$REPO" app/ledgerx/y.rb)"
check "**/ twice, nested"                   critical "$(tier_for_files "$REPO" a/x/b/y/c)"
check "**/ twice, zero levels"              critical "$(tier_for_files "$REPO" a/b/c)"
check "leading **/ with a name, nested"     standard "$(tier_for_files "$REPO" config/routes.rb)"
make_repo starslash '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `**/` | standard |'
check "**/ alone means everything"          standard "$(tier_for_files "$REPO" lib/x.rb)"
make_repo dotrules '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `./` | standard |'
check "rule ./ means everything"            standard "$(tier_for_files "$REPO" lib/x.rb)"
make_repo dotrule '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `.` | standard |'
check "rule . means everything"             standard "$(tier_for_files "$REPO" lib/x.rb)"
make_repo commentfence '# p

## Docs

```html
<!--
an open comment inside a fence
```

## Rigor

- Default: critical

<!--
```
-->

| Paths | Tier |
|---|---|
| `docs/` | light | <!-- reviewed -->
| <!-- a --> `lib/**` | standard | <!-- b --> |'
check "<!-- inside a fence is not a comment"     critical "$(tier_for_files "$REPO" README.md)"
check "a fence inside a comment is not a fence"  light    "$(tier_for_files "$REPO" docs/x.md)"
check "a row between two comments is kept"       standard "$(tier_for_files "$REPO" lib/x.rb)"
make_repo opencomment '## Rigor

- Default: critical

HTML comments (`<!--`) are skipped.

| Paths | Tier |
|---|---|
| `docs/` | light |'
check "<!-- in inline code is not a comment"     light    "$(tier_for_files "$REPO" docs/x.md)"
make_repo opencomment2 '## Rigor

- Default: critical

<!-- never closed

| Paths | Tier |
|---|---|
| `docs/` | light |'
err="$(cd "$REPO" && printf 'x\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "an unclosed comment is reported" yes "$([[ "$err" == *"comment"* ]] && echo yes || echo no)"
make_repo indentedfence '## Rigor

- Default: light
- Example:
    ```
    | `docs/` | critical |
    ```

| Paths | Tier |
|---|---|
| `lib/**` | standard |'
check "rows in a four-space-indented example are not rules" light "$(tier_for_files "$REPO" docs/x.md)"
make_repo closertext '## Rigor

- Default: light

```markdown
| `docs/` | critical |
``` trailing
| `lib/**` | critical |
```

| Paths | Tier |
|---|---|
| `app/**` | standard |'
check "a closing fence carries no text"         light    "$(tier_for_files "$REPO" lib/x.rb)"
check "the real table after it is parsed"       standard "$(tier_for_files "$REPO" app/x.rb)"
make_repo headerless '## Rigor

- Default: light

| `app/**` | critcal |
| `lib/**` | (critical) |'
err="$(cd "$REPO" && printf 'x\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "a typo in a headerless first row is reported" yes "$([[ "$err" == *"critcal"* ]] && echo yes || echo no)"
check "a tier in parentheses"                   critical "$(tier_for_files "$REPO" lib/x.rb)"
make_repo emphdefault '## Rigor

- Default: _light_'
check "Default in underscores"                  light    "$(tier_for_files "$REPO" README.md)"
make_repo quotedefault '## Rigor

- Default: "light"

| Paths | Tier |
|---|---|
| `app/**` | _critical_ |'
check "Default in double quotes"                light    "$(tier_for_files "$REPO" README.md)"
check "tier in underscores"                     critical "$(tier_for_files "$REPO" app/x.rb)"

# 24. round-4 gate findings
make_repo deep '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `**/*.md` | standard |
| `app/**/ledger/**` | critical |'
DEEP="app"; for i in $(seq 1 40); do DEEP="$DEEP/d$i"; done
if command -v perl >/dev/null 2>&1; then ALARM=(perl -e 'alarm 20; exec @ARGV'); else ALARM=(env); fi   # a hang fails the case within 20 s where perl exists
check "a 40-level non-matching path finishes"  light "$(cd "$REPO" && printf "%s\n" "$DEEP/y.rb" | "${ALARM[@]}" bash "$RIGOR" --files 2>/dev/null)"
check "a 40-level matching path"               standard "$(cd "$REPO" && printf "%s\n" "$DEEP/y.md" | "${ALARM[@]}" bash "$RIGOR" --files 2>/dev/null)"
make_repo trailglob '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/**/` | critical |
| `./**/` | standard |'
check "a rule ending in **/ is a prefix"       critical "$(tier_for_files "$REPO" app/x.rb)"
check "a rule ending in **/ is a prefix, nested" critical "$(tier_for_files "$REPO" app/sub/x.rb)"
check "./**/ alone means everything"          standard "$(tier_for_files "$REPO" lib/x.rb)"
make_repo fourspace '## Rigor

- Default: light
    | Paths | Tier |
    |---|---|
    | `app/**` | critical |'
check "a table indented four spaces under the bullet" critical "$(tier_for_files "$REPO" app/x.rb)"
make_repo nopipe '## Rigor

- Default: light

Paths | Tier
--- | ---
`app/**` | critical
| `lib/**` | |
| `docs/**` | ((standard)) |'
check "a row without a leading pipe"           critical "$(tier_for_files "$REPO" app/x.rb)"
err="$(cd "$REPO" && printf 'x\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "an empty tier cell is reported" yes "$([[ "$err" == *"lib/**"* ]] && echo yes || echo no)"
check "a tier in double parentheses"           standard "$(tier_for_files "$REPO" docs/x.md)"
make_repo squote '  ## Rigor

- Default: '"'"'critical'"'"'

| Paths | Tier |
|---|---|
| `app/api/\[id\]/route.ts` | light |

  ## Other

| Paths | Tier |
|---|---|
| `lib/**` | light |'
check "Default in single quotes, heading indented" critical "$(tier_for_files "$REPO" README.md)"
check "an escaped bracket names a literal path"  light    "$(tier_for_files "$REPO" "app/api/[id]/route.ts")"
check "an indented heading ends the section"     critical "$(tier_for_files "$REPO" lib/x.rb)"
make_repo strayalign '## Rigor

- Default: light

| `app/**` | critical |

|---|---|'
check "a data row before a stray alignment row is kept" critical "$(tier_for_files "$REPO" app/x.rb)"
make_repo reopen '## Rigor

- Default: light

<!--
x
--> | `docs/` | standard | <!-- still open
| `lib/**` | critical |
-->'
check "a line that closes and reopens a comment" standard "$(tier_for_files "$REPO" docs/x.md)"
check "the reopened comment hides the next row"  light    "$(tier_for_files "$REPO" lib/x.rb)"
err="$(cd "$TMP/deep" && printf 'config/routes.md\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "the reason shows the rule as written" yes "$([[ "$err" == *'`**/*.md`'* ]] && echo yes || echo no)"
make_repo emptysection '## Rigor

## Verification
none'
err="$(cd "$REPO" && printf 'x\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "an empty section is reported as empty" yes "$([[ "$err" == *"empty"* ]] && echo yes || echo no)"

# 25. round-5 gate findings
make_repo template "$(cat "$HERE/../../templates/workflow.md")"
err="$(cd "$REPO" && printf 'README.md\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "the shipped template makes no row-skipped note" no "$([[ "$err" == *"row skipped"* ]] && echo yes || echo no)"
check "the shipped template classifies README.md as light" light "$(tier_for_files "$REPO" README.md)"
check "the shipped template classifies source as its default" standard "$(tier_for_files "$REPO" lib/foo.rb)"
make_repo pipeprose '## Rigor

- Default: light | see the table

Rules are either `a` | `b` style.

| Paths | Tier |
|---|---|
| `lib/**` | standard |'
err="$(cd "$REPO" && printf 'x\n' | bash "$RIGOR" --files 2>&1 >/dev/null)"; check "prose with a pipe makes no note" no "$([[ "$err" == *"row skipped"* ]] && echo yes || echo no)"
check "the Default with a pipe still parses"      light    "$(tier_for_files "$REPO" README.md)"
check "the table after the prose still parses"   standard "$(tier_for_files "$REPO" lib/x.rb)"
make_repo escdir '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/\[id\]` | critical |
| `lib/+(x)` | critical |
| `**` | standard |'
mkdir -p "$REPO/app/[id]" "$REPO/lib/+(x)"
check "an escaped-bracket rule naming a directory is a prefix" critical "$(tier_for_files "$REPO" "app/[id]/page.tsx")"
check "an extglob rule stays a pattern even when a directory matches its text" critical "$(tier_for_files "$REPO" lib/xx)"
check "a rule with an extglob does not become a prefix" standard "$(tier_for_files "$REPO" "lib/+(x)/f")"
check "bare ** alone means everything"           standard "$(tier_for_files "$REPO" docs/x.md)"
make_repo doubletrail '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/**/**/` | critical |
| `**/**/` | standard |
| `.///` | standard |'
check "a doubled trailing **/ is a prefix"        critical "$(tier_for_files "$REPO" app/sub/x.rb)"
check "**/**/ alone means everything"            standard "$(tier_for_files "$REPO" lib/x.rb)"
make_repo slashes '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `.///` | standard |'
check "./// means everything"                    standard "$(tier_for_files "$REPO" lib/x.rb)"
make_repo datathenalign '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/**` | critical |
|---|---|'
check "a data row directly before a stray alignment row is kept" critical "$(tier_for_files "$REPO" app/x.rb)"
make_repo twosections '## Rigor

- Default: light

| Paths | Tier |
|---|---|
| `app/**` | critical |

## Docs

## Rigor

- Default: critical

| Paths | Tier |
|---|---|
| `lib/**` | standard |'
check "two sections: the first Default wins"     light    "$(tier_for_files "$REPO" README.md)"
check "two sections: rules from both apply"     standard "$(tier_for_files "$REPO" lib/x.rb)"

# 16. exit code is always 0
( cd "$TMP/noprofile" && printf 'x\n' | bash "$RIGOR" --files >/dev/null 2>&1 ); check "exit 0 without profile" 0 "$?"
( cd "$TMP/gitdiff" && bash "$RIGOR" nope >/dev/null 2>&1 ); check "exit 0 on bad ref" 0 "$?"

echo; echo "$n cases, $([[ $fail == 0 ]] && echo all passed || echo FAILURES)"
exit $fail
