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

# 16. exit code is always 0
( cd "$TMP/noprofile" && printf 'x\n' | bash "$RIGOR" --files >/dev/null 2>&1 ); check "exit 0 without profile" 0 "$?"
( cd "$TMP/gitdiff" && bash "$RIGOR" nope >/dev/null 2>&1 ); check "exit 0 on bad ref" 0 "$?"

echo; echo "$n cases, $([[ $fail == 0 ]] && echo all passed || echo FAILURES)"
exit $fail
