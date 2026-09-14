#!/usr/bin/env bash
# Print the effective Rigor tier for a diff: critical | standard | light.
#
#   rigor.sh [<base-ref>]        classify the files in <base-ref>...HEAD (default origin/main)
#   rigor.sh --files             classify the paths read from stdin, one per line
#                                (for /lode:lfg before anything is committed)
#
# Reads the "## Rigor" heading of lode/workflow.md:
#
#   - Default: standard
#   | Paths | Tier |
#   |---|---|
#   | `app/services/**`, `config/routes.rb` | critical |
#   | `docs/` | light |
#
# A rule is a bash pattern matched against the repo-relative path: `*` spans `/`,
# `**/` matches zero or more directory levels (gitignore style), `[...]` is a
# character class (so a literal bracket in a path, `app/[id]/page.tsx`, is written
# `\[id\]`), the extglob forms `?(…)`, `*(…)`, `+(…)`, `@(…)` and `!(…)` are
# honoured with a single alternative (a `|` ends the table cell, so `@(a|b)` cannot
# be written), and a rule with none of those characters is an exact path. A rule
# ending in `/` or `**/`, or naming a directory that exists, is a prefix; `/`, `.`,
# `**` and `**/` alone, with or without a leading `./`, are everything. Leading
# `./` or `/` on a rule or a path is ignored, and a path that names an existing
# directory counts as everything under it. Commas separate rules inside a cell, so
# a rule cannot contain one; two backticked rules with no comma between them are
# reported and the row is skipped. Fenced code blocks and HTML comments are
# skipped; a `<!--` or a `|` inside inline code is text. Any other line with a `|`
# in the section is a table row, indented or not; a row whose tier cell is not a
# tier word and which is immediately followed by an alignment row is a header. Two
# `## Rigor` sections are read as one; the first Default wins. `**/*` repeated
# three or more times in one rule is slow against paths dozens of levels deep.
#
# A file no rule names counts as the default; the diff takes the highest tier over
# its files. So a critical row in a light repo raises the diff, and a light row in a
# standard repo lowers a diff that touches only that path. A rename counts on both
# sides, so moving a file out of a critical directory is a critical change.
#
# Fails open to "standard", with the reason on stderr: no profile, no or empty
# heading, no or unknown Default, a git ref that does not resolve, a range git
# cannot diff. A data row whose tier cell is empty or not critical, standard or
# light is skipped with a note, and an unclosed fence or comment is reported.
# Exit is always 0; the tier is the one word on stdout. Bash 3.2.

set -u
set -f   # rules are patterns for [[ == ]], never for the filesystem
set -o pipefail
shopt -s extglob   # the documented requirement for `@(|*/)`; a pattern held in a variable matched without it on bash 3.2 and 5, kept anyway

BASE="origin/main"; FROM_STDIN=0
for arg in "$@"; do
  case "$arg" in
    --files) FROM_STDIN=1 ;;
    *) BASE="$arg" ;;
  esac
done

note() { echo "[lode:rigor] $1" >&2; }
rank() { case "$1" in critical) echo 3 ;; standard) echo 2 ;; light) echo 1 ;; *) echo 0 ;; esac; }
name() { case "$1" in 3) echo critical ;; 2) echo standard ;; 1) echo light ;; esac; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# strip any leading "./" and "/" so rules and paths compare the same way
unprefix() { local p="$1"; while [[ "$p" == ./* || "$p" == /* ]]; do p="${p#./}"; p="${p#/}"; done; printf '%s' "$p"; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROFILE="$ROOT/lode/workflow.md"
if [[ ! -f "$PROFILE" ]]; then
  note "no lode/workflow.md — tier standard"; echo standard; exit 0
fi

# The section body, minus fenced code blocks and HTML comments anywhere in the
# file, minus CRs. A fence closes only on a bare line of the same character with
# at least the opening length. Inside a fence nothing is a comment; inside a
# comment nothing is a fence. An ATX heading may be indented up to three spaces.
SECTION="$(tr -d '\r' < "$PROFILE" | awk '
  function fence_of(line,   s) {
    s = line; sub(/^[[:space:]]*/, "", s)
    if (s ~ /^```/) { sub(/[^`].*$/, "", s); return s }
    if (s ~ /^~~~/) { sub(/[^~].*$/, "", s); return s }
    return ""
  }
  function closer_of(line,   s) {
    s = line; sub(/^[[:space:]]*/, "", s); sub(/[[:space:]]*$/, "", s)
    if (s ~ /^(`+|~+)$/) return s
    return ""
  }
  function strip_comments(line,   d, a, b) {
    while (1) {
      d = line; gsub(/`[^`]*`/, "", d)                # a <!-- inside inline code is text
      if (index(d, "<!--") == 0) return line
      a = index(line, "<!--")
      b = index(substr(line, a + 4), "-->")
      if (b == 0) { comment = 1; comment_line = NR; return substr(line, 1, a - 1) }
      line = substr(line, 1, a - 1) substr(line, a + 4 + b + 2)
    }
  }
  comment { b = index($0, "-->"); if (b == 0) next; comment = 0; $0 = substr($0, b + 3) }
  open == "" { $0 = strip_comments($0) }
  open == "" { f = fence_of($0); if (f != "") { open = f; open_line = NR; next } }
  open != "" { c = closer_of($0); if (c != "" && substr(c, 1, 1) == substr(open, 1, 1) && length(c) >= length(open)) open = ""; next }
  /^ ? ? ?## Rigor[[:space:]]*#*[[:space:]]*$/ { in_section = 1; found = 1; next }
  /^ ? ? ?## / { in_section = 0 }
  in_section
  END {
    if (open != "") print "[lode:rigor] a fenced block opened at line " open_line " of lode/workflow.md is never closed; everything after it was skipped" > "/dev/stderr"
    if (comment) print "[lode:rigor] an HTML comment opened at line " comment_line " of lode/workflow.md is never closed; everything after it was skipped" > "/dev/stderr"
    if (found) print "\001found"
  }')"
if [[ "$SECTION" != *$'\001found' ]]; then
  note "no ## Rigor heading in lode/workflow.md — tier standard"; echo standard; exit 0
fi
SECTION="${SECTION%$'\001found'}"
if [[ -z "$(trim "$SECTION")" ]]; then
  note "the ## Rigor heading in lode/workflow.md is empty — tier standard"; echo standard; exit 0
fi

DEFAULT_RE='^[[:space:]]*[-*]*[[:space:]]*\**[Dd]efault\**:\**[[:space:]]*[*_"'\'']*`\{0,1\}\([A-Za-z-]*\).*$'
DEFAULT="$(printf '%s\n' "$SECTION" | sed -n "s/$DEFAULT_RE/\\1/p" | head -1)"
DEFAULT="$(lower "$DEFAULT")"
case "$DEFAULT" in
  critical|standard|light) ;;
  "") note "no 'Default:' line under ## Rigor — tier standard"; DEFAULT=standard ;;
  *) note "unknown default '$DEFAULT' under ## Rigor — tier standard"; DEFAULT=standard ;;
esac

# Rules: one "<pattern><TAB><tier><TAB><rule as written>" per line, from every
# data row with a known tier.
lines=()
while IFS= read -r l; do lines+=("$(trim "$l")"); done <<< "$SECTION"
is_alignment() { local s="${1//[|: -]/}"; [[ "$1" == *[-:]* && -z "$s" ]]; }
is_row() {   # a line with a | outside inline code, that is not the Default line
  local d="${1//\`*\`/}"
  [[ "$d" == *\|* ]] || return 1
  ! printf '%s\n' "$1" | sed -n "/$DEFAULT_RE/p" | grep -q .
}
RULES=""; n=${#lines[@]}
for (( i = 0; i < n; i++ )); do
  line="${lines[$i]}"
  is_row "$line" || continue
  is_alignment "$line" && continue
  body="${line#|}"
  paths="$(trim "${body%%|*}")"
  rest="${body#*|}"; tier="$(trim "${rest%%|*}")"
  tier="${tier//\`/}"; tier="${tier//\*/}"; tier="${tier//_/}"; tier="$(trim "$tier")"
  while [[ "$tier" == \(* ]]; do tier="${tier#(}"; done
  tier="$(lower "$tier")"; tier="${tier%%[[:space:](),]*}"
  case "$tier" in
    critical|standard|light) ;;
    *) # a non-tier row immediately followed by an alignment row is the header
       (( i + 1 < n )) && is_alignment "${lines[$((i + 1))]}" && continue
       note "row skipped, unknown tier '$tier': $line"; continue ;;
  esac
  case "$paths" in
    *\`*\`*\`*) [[ "$paths" == *,* ]] || { note "row skipped, patterns must be comma-separated: $line"; continue; } ;;
  esac
  paths="${paths//\`/}"
  oldifs="$IFS"; IFS=','
  for raw in $paths; do
    raw="$(trim "$raw")"
    [[ -n "$raw" ]] || continue
    pat="$(unprefix "$raw")"
    while [[ "$pat" == *'**/' && "$pat" != '**/' ]]; do pat="${pat%'**/'}"; done   # `dir/**/` is the prefix `dir/`
    case "$pat" in ''|.|'**'|'**/') pat='*' ;; *) pat="${pat//\*\*\//@(|*\/)}" ;; esac
    RULES="${RULES}${pat}	${tier}	${raw}
"
  done
  IFS="$oldifs"
done

# Changed files.
if [[ "$FROM_STDIN" == "1" ]]; then
  FILES="$(cat)"
else
  if ! git -C "$ROOT" rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null; then
    note "base ref '$BASE' does not resolve — tier standard"; echo standard; exit 0
  fi
  if ! FILES="$(git -C "$ROOT" diff --name-only --no-renames -z "${BASE}...HEAD" 2>/dev/null | tr '\0' '\n')"; then
    note "git cannot diff ${BASE}...HEAD (no merge base?) — tier standard"; echo standard; exit 0
  fi
fi

best=0; reason=""
while IFS= read -r file; do
  file="$(unprefix "$(trim "$file")")"
  [[ -n "$file" ]] || continue
  [[ "$file" != */ && -d "$ROOT/$file" ]] && file="$file/"
  fbest=0; freason=""
  while IFS='	' read -r pat tier raw; do
    [[ -n "$pat" ]] || continue
    unescaped="${pat//\\?/}"   # pattern characters that are escaped do not count
    if [[ "$pat" == */ ]]; then match="${pat}*"
    elif [[ "$unescaped" != *[\*\?\[\(]* && -d "$ROOT/${pat//\\/}" ]]; then match="${pat}/*"
    else match="$pat"; fi
    # shellcheck disable=SC2053  # unquoted on purpose: the rule is a pattern
    if [[ "$file" == $match ]]; then
      r="$(rank "$tier")"
      if (( r > fbest )); then fbest="$r"; freason="$file matches \`$raw\` → $tier"; fi
    fi
  done <<< "$RULES"
  (( fbest > 0 )) || fbest="$(rank "$DEFAULT")"
  if (( fbest > best )); then best="$fbest"; reason="$freason"; fi
done <<< "$FILES"

(( best > 0 )) || best="$(rank "$DEFAULT")"
[[ -n "$reason" ]] && note "$reason"
name "$best"
exit 0
