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
# so `**` and `*` are the same); a rule ending in `/` is a directory prefix; anything
# else is an exact path. The tier is the highest tier any changed file matches, else
# the default. Highest wins, so a critical row in a light repo raises the diff.
#
# Fails open to "standard", with the reason on stderr: no profile, no heading, no
# or unknown Default, a git ref that does not resolve. A row with an unknown tier
# is skipped. Exit is always 0; the tier is the one word on stdout. Bash 3.2.

set -u

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

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROFILE="$ROOT/lode/workflow.md"
if [[ ! -f "$PROFILE" ]]; then
  note "no lode/workflow.md — tier standard"; echo standard; exit 0
fi

SECTION="$(awk '/^## Rigor[[:space:]]*$/{f=1; next} /^## /{f=0} f' "$PROFILE")"
if [[ -z "$SECTION" ]]; then
  note "no ## Rigor heading in lode/workflow.md — tier standard"; echo standard; exit 0
fi

DEFAULT="$(printf '%s\n' "$SECTION" | sed -n 's/^[-*]*[[:space:]]*Default:[[:space:]]*`\{0,1\}\([a-z]*\)`\{0,1\}.*$/\1/p' | head -1)"
case "$DEFAULT" in
  critical|standard|light) ;;
  "") note "no 'Default:' line under ## Rigor — tier standard"; DEFAULT=standard ;;
  *) note "unknown default '$DEFAULT' under ## Rigor — tier standard"; DEFAULT=standard ;;
esac

# Rules: one "<pattern><TAB><tier>" per line, from every table row with a known tier.
RULES=""
while IFS= read -r line; do
  [[ "$line" == \|* ]] || continue
  body="${line#|}"; body="${body%|}"
  paths="$(trim "${body%%|*}")"
  tier="$(trim "${body#*|}")"; tier="${tier%%|*}"; tier="$(trim "$tier")"; tier="${tier//\`/}"
  case "$tier" in
    critical|standard|light) ;;
    *) continue ;;   # header, separator, or a row with an unknown tier
  esac
  paths="${paths//\`/}"
  oldifs="$IFS"; IFS=','
  for pat in $paths; do
    pat="$(trim "$pat")"
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
    note "base ref '$BASE' does not resolve — tier $DEFAULT"; echo "$DEFAULT"; exit 0
  fi
  FILES="$(git -C "$ROOT" diff --name-only "${BASE}...HEAD" 2>/dev/null)"
fi

best=0; reason=""
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  fbest=0
  while IFS='	' read -r pat tier; do
    [[ -n "$pat" ]] || continue
    if [[ "$pat" == */ ]]; then match="${pat}*"; else match="$pat"; fi
    # shellcheck disable=SC2053  # unquoted on purpose: the rule is a pattern
    if [[ "$file" == $match ]]; then
      r="$(rank "$tier")"
      if (( r > fbest )); then fbest="$r"; freason="$file matches \`$pat\` → $tier"; fi
    fi
  done <<< "$RULES"
  (( fbest > 0 )) || fbest="$(rank "$DEFAULT")"
  if (( fbest > best )); then best="$fbest"; reason="${freason:-}"; fi
done <<< "$FILES"

(( best > 0 )) || best="$(rank "$DEFAULT")"
[[ -n "$reason" ]] && note "$reason"
name "$best"
exit 0
