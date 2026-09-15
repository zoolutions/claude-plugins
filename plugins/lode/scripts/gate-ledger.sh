#!/usr/bin/env bash
# The gate's per-branch ledger: what its agents have seen and what a gate invocation has spent.
#
#   gate-ledger.sh begin [<base>] [--tier t [--why "<reason>"]] [--rounds N]
#       Start a gate invocation on the current branch. Resolves the tier through rigor.sh
#       (--tier overrides; lowering needs --why), sets the round cap (1 / 3 / 5 by tier, or
#       --rounds), resets the per-invocation counters and keeps what earlier invocations on
#       this branch reviewed. Prints tier=, cap=, invocation=, base=.
#   gate-ledger.sh round
#       Before a fan-out. Refuses past the cap. Writes lode/tmp/gate/diff.patch (the whole
#       <base>...HEAD, context) and lode/tmp/gate/delta.patch (what the agents review): the
#       full diff the first time a branch is seen, afterwards only what the branch added since
#       the last round — each non-merge commit's own diff, and for a merge commit its combined
#       diff, which is empty for a clean merge and holds only the resolution for a resolved
#       one. Prints round=, range=, delta_lines=, tier=, cap=.
#   gate-ledger.sh spawn <lode:gate-agent> [<model>]
#       The decision behind hooks' pre-agent-gate.sh: exit 0 and record the spawn, or exit 1
#       with the reason (no ledger, another branch, no round yet, outside the tier's set,
#       a model override on an agent that declares one, or the per-agent cap reached).
#   gate-ledger.sh pass [--deferred N] [--p1 N]
#       Record the pass: writes lode/tmp/gate-passed with the tree= line the push hook reads
#       plus tier=, override=, rounds=, agents=, deferred=. Refuses a dirty tree, an open P1,
#       or a branch no round has run on.
#   gate-ledger.sh show
#       Print the Spent block the skills paste into their reports.
#
# The ledger is lode/tmp/gate/ledger, key=value lines. seen= is the HEAD at the last round
# (the delta's start); reviewed= is the HEAD at the last pass. Bash 3.2.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "gate-ledger: not inside a git repository" >&2; exit 1; }
DIR="$ROOT/lode/tmp/gate"
LEDGER="$DIR/ledger"
MARKER="$ROOT/lode/tmp/gate-passed"

die() { echo "gate-ledger: $1" >&2; exit 1; }
refuse() { echo "$1" >&2; exit 1; }
lget() { [[ -f "$LEDGER" ]] || return 0; sed -n "s/^$(printf '%s' "$1" | sed 's/[.]/\\./g')=//p" "$LEDGER" | head -1; }
lset() { # lset <key> <value> — replace the key's line, keep everything else
  local pat tmp
  pat="^$(printf '%s' "$1" | sed 's/[.]/\\./g')="
  tmp="$LEDGER.tmp"
  { [[ -f "$LEDGER" ]] && grep -v "$pat" "$LEDGER"; printf '%s=%s\n' "$1" "$2"; } > "$tmp"
  mv "$tmp" "$LEDGER"
}
lappend() { printf '%s\n' "$1" >> "$LEDGER"; }
current_branch() { local b; b="$(git branch --show-current 2>/dev/null)"; printf '%s' "${b:-detached}"; }
cap_for() { case "$1" in light) echo 1 ;; critical) echo 5 ;; *) echo 3 ;; esac; }
rank_of() { case "$1" in light) echo 1 ;; standard) echo 2 ;; critical) echo 3 ;; *) echo 0 ;; esac; }
need_ledger() {
  [[ -f "$LEDGER" ]] || refuse "no gate ledger for this branch: run \`bash ${HERE}/gate-ledger.sh begin\` and then \`round\` before spawning gate agents"
  local want; want="$(current_branch)"
  [[ "$(lget branch)" == "$want" ]] || refuse "the gate ledger is for branch $(lget branch), HEAD is on $want: run \`gate-ledger.sh begin\` on this branch"
}
agents_summary() { # "gate-rules x3 (sonnet), gate-tests x1 (sonnet)"
  [[ -f "$LEDGER" ]] || return 0
  sed -n 's/^spawned=[0-9]*://p' "$LEDGER" | sort | uniq -c | awk '{
    split($2, a, ":"); s = a[1] " x" $1; if (a[2] != "") s = s " (" a[2] ")";
    out = (out == "" ? s : out ", " s) } END { printf "%s", out }'
}

cmd="${1:-}"; shift || true
case "$cmd" in

begin)
  base=""; tier=""; why=""; rounds=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tier) tier="${2:-}"; shift 2 ;;
      --why) why="${2:-}"; shift 2 ;;
      --rounds) rounds="${2:-}"; shift 2 ;;
      --*) die "unknown option $1" ;;
      *) base="$1"; shift ;;
    esac
  done
  base="${base:-origin/main}"
  git rev-parse --verify -q "${base}^{commit}" >/dev/null || die "base ref '$base' does not resolve; fetch it or name another"
  profile_tier="$(bash "$HERE/rigor.sh" "$base" 2>/dev/null)"; profile_tier="${profile_tier:-standard}"
  if [[ -n "$tier" ]]; then
    case "$tier" in critical|standard|light) ;; *) die "--tier must be critical, standard or light" ;; esac
    if [[ "$(rank_of "$tier")" -lt "$(rank_of "$profile_tier")" && -z "$why" ]]; then
      die "--tier $tier lowers the profile's $profile_tier; say why with --why \"<reason>\""
    fi
    [[ "$tier" == "$profile_tier" ]] && why=""
  else
    tier="$profile_tier"
  fi
  cap="$(cap_for "$tier")"
  if [[ -n "$rounds" ]]; then
    [[ "$rounds" =~ ^[1-9][0-9]*$ ]] || die "--rounds must be a positive integer"
    cap="$rounds"
  fi
  branch="$(current_branch)"
  mkdir -p "$DIR"
  seen=""; reviewed=""; inv=0
  if [[ -f "$LEDGER" && "$(lget branch)" == "$branch" ]]; then
    seen="$(lget seen)"; reviewed="$(lget reviewed)"; inv="$(lget invocations)"; inv="${inv:-0}"
  fi
  inv=$((inv + 1))
  {
    printf 'branch=%s\nbase=%s\ntier=%s\noverride=%s\ncap=%s\ninvocations=%s\nround=0\n' "$branch" "$base" "$tier" "$why" "$cap" "$inv"
    [[ -n "$seen" ]] && printf 'seen=%s\n' "$seen"
    [[ -n "$reviewed" ]] && printf 'reviewed=%s\n' "$reviewed"
  } > "$LEDGER"
  printf 'tier=%s\ncap=%s\ninvocation=%s\nbase=%s\n' "$tier" "$cap" "$inv" "$base"
  ;;

round)
  need_ledger
  round="$(lget round)"; round="${round:-0}"; cap="$(lget cap)"; tier="$(lget tier)"; base="$(lget base)"; seen="$(lget seen)"
  next=$((round + 1))
  if [[ "$next" -gt "$cap" ]]; then
    refuse "round limit of $cap reached at tier $tier: record the pass with the remaining P2s deferred (\`gate-ledger.sh pass --deferred N\`), or report the P1 and record nothing"
  fi
  mkdir -p "$DIR"
  git diff --no-color "${base}...HEAD" > "$DIR/diff.patch"
  head="$(git rev-parse HEAD)"
  range="${base}...HEAD"; kind=full
  if [[ -z "$seen" ]]; then
    cp "$DIR/diff.patch" "$DIR/delta.patch"
  elif ! git merge-base --is-ancestor "$seen" HEAD 2>/dev/null; then
    echo "gate-ledger: the last reviewed commit ${seen:0:12} is not an ancestor of HEAD (branch rewritten?): reviewing the full diff" >&2
    cp "$DIR/diff.patch" "$DIR/delta.patch"
  else
    range="${seen}..HEAD"; kind=delta
    : > "$DIR/delta.patch"
    for c in $(git rev-list --reverse "${seen}..HEAD" "^${base}"); do
      git show --format= --no-color "$c" >> "$DIR/delta.patch"
    done
  fi
  lines="$(wc -l < "$DIR/delta.patch" | tr -d ' ')"
  lset round "$next"; lset seen "$head"; lset "delta.$next" "$lines"; lset "kind.$next" "$kind"
  printf 'round=%s\nrange=%s\ndelta_lines=%s\ntier=%s\ncap=%s\n' "$next" "$range" "$lines" "$tier" "$cap"
  ;;

spawn)
  agent="${1:-}"; model="${2:-}"
  [[ -n "$agent" ]] || die "spawn needs the agent name"
  need_ledger
  round="$(lget round)"; round="${round:-0}"
  [[ "$round" -ge 1 ]] || refuse "run \`gate-ledger.sh round\` first: it writes lode/tmp/gate/delta.patch, the diff the agents review"
  tier="$(lget tier)"; cap="$(lget cap)"
  name="${agent#lode:}"
  case "$tier" in
    light) set_="gate-tests gate-rules gate-parser" ;;
    *) set_="gate-tests gate-rules gate-parser gate-correctness gate-claims" ;;
  esac
  case " $set_ " in
    *" $name "*) ;;
    *) refuse "$name is not in the $tier gate (its agents: $set_)" ;;
  esac
  declared="$(sed -n 's/^model: *//p' "$HERE/../agents/$name.md" 2>/dev/null | head -1)"
  if [[ -n "$model" && -n "$declared" && "$declared" != inherit && "$declared" != "$model" ]]; then
    refuse "$name declares model: $declared; spawning it on $model is not allowed — drop the model override"
  fi
  percap="$cap"
  [[ "$tier" == critical && "$name" == gate-correctness ]] && percap=$((cap * 2))
  count="$(lget "spawn.$name")"; count="${count:-0}"
  if [[ "$count" -ge "$percap" ]]; then
    refuse "spawn $((count + 1)) of $name exceeds the cap of $percap at tier $tier (the round limit): record the pass with the remaining P2s deferred (\`gate-ledger.sh pass --deferred N\`), or report the P1 and record nothing"
  fi
  lset "spawn.$name" $((count + 1))
  lappend "spawned=$round:$name:${model:-$declared}"
  ;;

pass)
  deferred=0; p1=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deferred) deferred="${2:-0}"; shift 2 ;;
      --p1) p1="${2:-0}"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  need_ledger
  round="$(lget round)"; round="${round:-0}"
  [[ "$round" -ge 1 ]] || refuse "no round has run on this branch; nothing was reviewed"
  [[ -z "$(git status --porcelain)" ]] || refuse "the working tree is dirty: commit before recording a pass"
  [[ "$p1" -eq 0 ]] || refuse "$p1 confirmed P1 remain: no pass is recorded; fix them, or report and stop"
  head="$(git rev-parse HEAD)"
  lset reviewed "$head"
  printf 'tree=%s\nreport=lode/tmp/gate/report.md\nat=%s\ntier=%s\noverride=%s\nrounds=%s\nagents=%s\ndeferred=%s\n' \
    "$(git rev-parse 'HEAD^{tree}')" "$(date -u +%FT%TZ)" "$(lget tier)" "$(lget override)" "$round" "$(agents_summary)" "$deferred" > "$MARKER"
  printf 'pass recorded on tree %s (rounds %s, deferred %s)\n' "$(git rev-parse --short 'HEAD^{tree}')" "$round" "$deferred"
  ;;

show)
  [[ -f "$LEDGER" ]] || die "no gate ledger in this repository"
  tier="$(lget tier)"; override="$(lget override)"; round="$(lget round)"; cap="$(lget cap)"
  per_round=""
  i=1
  while [[ "$i" -le "${round:-0}" ]]; do
    l="$(lget "delta.$i")"; k="$(lget "kind.$i")"
    per_round="${per_round}${per_round:+, }round $i: ${l:-?} lines${k:+ ($k)}"
    i=$((i + 1))
  done
  passed=no
  if [[ -f "$MARKER" && "$(sed -n 's/^tree=//p' "$MARKER" | head -1)" == "$(git rev-parse 'HEAD^{tree}')" ]]; then passed=yes; fi
  printf 'Spent: invocation %s on %s, tier %s%s\n' "$(lget invocations)" "$(lget branch)" "$tier" "${override:+ (override: $override)}"
  printf '  rounds: %s of %s — %s\n' "${round:-0}" "$cap" "${per_round:-none}"
  printf '  agents: %s\n' "$(agents_summary)"
  printf '  reviewed through %s; pass recorded on HEAD: %s\n' "$(lget reviewed | cut -c1-12)" "$passed"
  ;;

*)
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
  ;;
esac
