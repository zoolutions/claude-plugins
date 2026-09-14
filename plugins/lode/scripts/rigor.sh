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
# `**/` also matches zero directory levels (gitignore style), `[...]` is a
# character class. A rule ending in `/`, or naming a directory that exists, is a
# prefix; `/` alone is everything; anything else is an exact path. Leading `./`
# or `/` on a rule or a path is ignored, and a path that names an existing
# directory counts as everything under it. Commas separate rules inside a cell,
# so a rule cannot contain one; two backticked rules with no comma between them
# are reported and the row is skipped. Fenced code blocks and HTML comments are
# skipped. The first row of a table is its header; alignment rows are structure.
#
# A file no rule names counts as the default; the diff takes the highest tier over
# its files. So a critical row in a light repo raises the diff, and a light row in a
# standard repo lowers a diff that touches only that path. A rename counts on both
# sides, so moving a file out of a critical directory is a critical change.
#
# Fails open to "standard", with the reason on stderr: no profile, no heading, no
# or unknown Default, a git ref that does not resolve, a range git cannot diff. A
# data row whose tier is not critical, standard or light is skipped with a note.
# Exit is always 0; the tier is the one word on stdout. Bash 3.2.

set -u
set -f   # rules are patterns for [[ == ]], never for the filesystem
set -o pipefail

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
# strip a leading "./" or "/" so rules and paths compare the same way
unprefix() { local p="$1"; while [[ "$p" == ./* ]]; do p="${p#./}"; done; p="${p#/}"; printf '%s' "$p"; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROFILE="$ROOT/lode/workflow.md"
if [[ ! -f "$PROFILE" ]]; then
  note "no lode/workflow.md — tier standard"; echo standard; exit 0
fi

# The section body, minus fenced code blocks and HTML comments anywhere in the
# file, minus CRs. A fence closes only on the same character with at least the
# opening length; an indented code line (four spaces or a tab) is not a fence.
SECTION="$(tr -d '\r' < "$PROFILE" | awk '
  function fence_of(line,   s) {
    if (line ~ /^(    |\t)/) return ""
    s = line; sub(/^[[:space:]]*/, "", s)
    if (s ~ /^```/) { sub(/[^`].*$/, "", s); return s }
    if (s ~ /^~~~/) { sub(/[^~].*$/, "", s); return s }
    return ""
  }
  comment { if (index($0, "-->")) { comment = 0; sub(/^.*-->/, "") } else next }
  { gsub(/<!--.*-->/, "") }
  index($0, "<!--") { sub(/<!--.*$/, ""); comment = 1 }
  { f = fence_of($0) }
  open == "" && f != "" { open = f; open_line = NR; next }
  open != "" { if (f != "" && substr(f, 1, 1) == substr(open, 1, 1) && length(f) >= length(open)) open = ""; next }
  /^## Rigor[[:space:]]*#*[[:space:]]*$/ { in_section = 1; next }
  /^## / { in_section = 0 }
  in_section
  END { if (open != "") print "[lode:rigor] a fenced block opened at line " open_line " of lode/workflow.md is never closed; everything after it was skipped" > "/dev/stderr" }')"
if [[ -z "$(trim "$SECTION")" ]]; then
  note "no ## Rigor heading in lode/workflow.md — tier standard"; echo standard; exit 0
fi

DEFAULT="$(printf '%s\n' "$SECTION" \
  | sed -n 's/^[[:space:]]*[-*]*[[:space:]]*\**[Dd]efault\**:\**[[:space:]]*[*_"]*`\{0,1\}\([A-Za-z_-]*\).*$/\1/p' | head -1)"
DEFAULT="$(lower "$DEFAULT")"
case "$DEFAULT" in
  critical|standard|light) ;;
  "") note "no 'Default:' line under ## Rigor — tier standard"; DEFAULT=standard ;;
  *) note "unknown default '$DEFAULT' under ## Rigor — tier standard"; DEFAULT=standard ;;
esac

# Rules: one "<pattern><TAB><tier>" per line, from every data row with a known tier.
RULES=""; prev_was_row=0
while IFS= read -r line; do
  line="$(trim "$line")"
  if [[ "$line" != \|* ]]; then prev_was_row=0; continue; fi
  first_row=$(( prev_was_row == 0 )); prev_was_row=1
  body="${line#|}"
  paths="$(trim "${body%%|*}")"
  rest="${body#*|}"; tier="$(trim "${rest%%|*}")"
  tier="${tier//\`/}"; tier="${tier//\*/}"; tier="${tier//_/}"; tier="$(lower "$(trim "$tier")")"; tier="${tier%%[[:space:](,]*}"
  case "$tier" in
    critical|standard|light) ;;
    -*|:*|"") continue ;;                       # the alignment row, an empty cell
    *) (( first_row )) || note "row skipped, unknown tier '$tier': $line"; continue ;;   # a header, or a typo
  esac
  case "$paths" in
    *\`*\`*\`*) [[ "$paths" == *,* ]] || { note "row skipped, patterns must be comma-separated: $line"; continue; } ;;
  esac
  paths="${paths//\`/}"
  oldifs="$IFS"; IFS=','
  for pat in $paths; do
    pat="$(trim "$pat")"
    [[ -n "$pat" ]] || continue
    case "$pat" in /|./|.) pat='*' ;; *) pat="$(unprefix "$pat")"; pat="${pat//\*\*\//}" ;; esac
    [[ -n "$pat" ]] || continue
    RULES="${RULES}${pat}	${tier}
"
  done
  IFS="$oldifs"
done <<< "$SECTION"

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
  while IFS='	' read -r pat tier; do
    [[ -n "$pat" ]] || continue
    if [[ "$pat" == */ ]]; then match="${pat}*"
    elif [[ "$pat" != *[\*\?\[]* && -d "$ROOT/$pat" ]]; then match="${pat}/*"
    else match="$pat"; fi
    # shellcheck disable=SC2053  # unquoted on purpose: the rule is a pattern
    if [[ "$file" == $match ]]; then
      r="$(rank "$tier")"
      if (( r > fbest )); then fbest="$r"; freason="$file matches \`$pat\` → $tier"; fi
    fi
  done <<< "$RULES"
  (( fbest > 0 )) || fbest="$(rank "$DEFAULT")"
  if (( fbest > best )); then best="$fbest"; reason="$freason"; fi
done <<< "$FILES"

(( best > 0 )) || best="$(rank "$DEFAULT")"
[[ -n "$reason" ]] && note "$reason"
name "$best"
exit 0
