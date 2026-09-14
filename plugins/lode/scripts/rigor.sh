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
# A rule is a bash pattern matched against the repo-relative path (`*` spans `/`,
# so `**` and `*` are the same; `[...]` is a character class). A rule ending in
# `/`, or naming a directory that exists, is a prefix; anything else is an exact
# path. Leading `./` or `/` on a rule or a path is ignored. Commas separate rules
# inside a cell, so a rule cannot contain one. Fenced code blocks are skipped.
#
# A file no rule names counts as the default; the diff takes the highest tier over
# its files. So a critical row in a light repo raises the diff, and a light row in a
# standard repo lowers a diff that touches only that path.
#
# Fails open to "standard", with the reason on stderr: no profile, no heading, no
# or unknown Default, a git ref that does not resolve. A row whose tier is not
# critical, standard or light is skipped with a note. Exit is always 0; the tier
# is the one word on stdout. Bash 3.2.

set -u
set -f   # rules are patterns for [[ == ]], never for the filesystem

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

# The section body, minus fenced code blocks anywhere in the file, minus CRs.
SECTION="$(tr -d '\r' < "$PROFILE" | awk '
  /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
  fence { next }
  /^## Rigor[[:space:]]*$/ { f = 1; next }
  /^## / { f = 0 }
  f')"
if [[ -z "$(trim "$SECTION")" ]]; then
  note "no ## Rigor heading in lode/workflow.md — tier standard"; echo standard; exit 0
fi

DEFAULT="$(printf '%s\n' "$SECTION" \
  | sed -n 's/^[[:space:]]*[-*]*[[:space:]]*\**[Dd]efault\**:\**[[:space:]]*`\{0,1\}\([A-Za-z_-]*\).*$/\1/p' | head -1)"
DEFAULT="$(lower "$DEFAULT")"
case "$DEFAULT" in
  critical|standard|light) ;;
  "") note "no 'Default:' line under ## Rigor — tier standard"; DEFAULT=standard ;;
  *) note "unknown default '$DEFAULT' under ## Rigor — tier standard"; DEFAULT=standard ;;
esac

# Rules: one "<pattern><TAB><tier>" per line, from every table row with a known tier.
RULES=""
while IFS= read -r line; do
  [[ "$line" == \|* ]] || continue
  body="${line#|}"
  paths="$(trim "${body%%|*}")"
  rest="${body#*|}"; tier="$(trim "${rest%%|*}")"
  tier="${tier//\`/}"; tier="${tier//\*/}"; tier="$(lower "$(trim "$tier")")"; tier="${tier%%[[:space:](]*}"
  case "$tier" in
    critical|standard|light) ;;
    tier|"") continue ;;                        # the header row, the separator, an empty cell
    *) [[ "$tier" == -* ]] || note "row skipped, unknown tier '$tier': $line"; continue ;;
  esac
  paths="${paths//\`/}"
  oldifs="$IFS"; IFS=','
  for pat in $paths; do
    pat="$(unprefix "$(trim "$pat")")"
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
  FILES="$(git -C "$ROOT" -c core.quotepath=off diff --name-only "${BASE}...HEAD" 2>/dev/null)"
fi

best=0; reason=""
while IFS= read -r file; do
  file="$(unprefix "$(trim "$file")")"
  [[ -n "$file" ]] || continue
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
