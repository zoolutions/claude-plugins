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
#       the last round: each non-merge commit's own diff, and for a merge commit the files both
#       sides changed since they diverged, diffed against each parent — empty when the two
#       sides touched different files, and showing a one-sided resolution as the revert it is.
#       Prints round=, range=, delta_lines=, tier=, cap=. Fails (exit 1) when the base has no
#       merge base with HEAD, so a shallow clone never reads as "nothing to review".
#   gate-ledger.sh spawn <lode:gate-agent> [<model>]
#       The decision behind pre-agent-gate.sh: exit 0 and record the spawn (one appended
#       line, so parallel spawns do not race), or exit 3 with the reason (no ledger, another
#       branch, no round yet, outside the tier's set, a model override on an agent that
#       declares one, or the per-agent cap reached: the round cap, twice that for
#       gate-correctness at critical, which runs twice per round). Any other failure is
#       exit 1, which the hook reads as "could not decide" and allows.
#   gate-ledger.sh pass [--deferred N] [--p1 N]
#       Record the pass: writes lode/tmp/gate-passed with the tree= line the push hook reads
#       plus report=, at=, tier=, override=, rounds=, agents=, deferred=. Refuses a dirty
#       tree, an open P1, or a branch no round has run on.
#   gate-ledger.sh show
#       Print the Spent block the skills paste into their reports.
#
# The ledger is lode/tmp/gate/ledger, key=value lines, one per worktree: a branch switch or
# a different base starts it over. seen= is the HEAD at the last round (the delta's start);
# reviewed= is the HEAD at the last pass. Bash 3.2. LODE_AGENTS_DIR overrides where the
# agent definitions are read from (tests).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "gate-ledger: not inside a git repository" >&2; exit 1; }
DIR="$ROOT/lode/tmp/gate"
LEDGER="$DIR/ledger"
MARKER="$ROOT/lode/tmp/gate-passed"
AGENTS_DIR="${LODE_AGENTS_DIR:-$HERE/../agents}"
GIT_DIFF="git diff --no-color --no-ext-diff"

die() { echo "gate-ledger: $1" >&2; exit 1; }
refuse() { echo "$1" >&2; exit 3; }   # a policy refusal; the hook denies only on 3
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
is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }
need_value() { [[ $# -ge 2 ]] || die "$1 needs a value"; }
spawn_count() { [[ -f "$LEDGER" ]] || { echo 0; return; }; grep -c "^spawned=[0-9]*:$1:" "$LEDGER" || true; }
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2; exit 1; }
declared_model() { # the model: line inside the frontmatter of agents/<name>.md, unquoted, trimmed
  awk 'NR == 1 { if ($0 != "---") exit; next }
       /^---[ \t\r]*$/ { exit }
       /^model:/ { sub(/^model:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/["\047\r]/, ""); sub(/[ \t]+$/, ""); print; exit }' "$AGENTS_DIR/$1.md" 2>/dev/null
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
      --tier) need_value "$@"; tier="$2"; shift 2 ;;
      --why) need_value "$@"; why="$(printf '%s' "$2" | tr '\n\r' '  ')"; shift 2 ;;
      --rounds) need_value "$@"; rounds="$2"; shift 2 ;;
      --*) die "unknown option $1" ;;
      *) base="$1"; shift ;;
    esac
  done
  base="${base:-origin/main}"
  git rev-parse --verify -q "${base}^{commit}" >/dev/null || die "base ref '$base' does not resolve; fetch it or name another"
  git merge-base "$base" HEAD >/dev/null 2>&1 || die "no merge base between $base and HEAD (a shallow clone?): deepen the history before gating"
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
    if [[ "$(lget base)" == "$base" ]]; then
      seen="$(lget seen)"; reviewed="$(lget reviewed)"; inv="$(lget invocations)"; inv="${inv:-0}"
    else
      echo "gate-ledger: the base changed from $(lget base) to $base; the next round reviews the full diff" >&2
    fi
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
  git merge-base "$base" HEAD >/dev/null 2>&1 || die "no merge base between $base and HEAD (a shallow clone?): deepen the history before gating"
  $GIT_DIFF "${base}...HEAD" > "$DIR/diff.patch" || die "git diff ${base}...HEAD failed; nothing was reviewed"
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
      parents="$(git rev-list --parents -n 1 "$c" | cut -d' ' -f2-)"
      if [[ "$parents" == *" "* ]]; then
        # A merge: the files both sides changed since they diverged, against each parent. A
        # hand-combined resolution, a one-sided one, and an edit smuggled into the merge all
        # show; two sides that touched different files leave nothing.
        p1="${parents%% *}"; p2="${parents#* }"; p2="${p2%% *}"
        mb="$(git merge-base "$p1" "$p2" 2>/dev/null || true)"
        both="$(comm -12 <($GIT_DIFF --name-only "${mb:-$p1}" "$p1" | sort) <($GIT_DIFF --name-only "${mb:-$p2}" "$p2" | sort))"
        if [[ -n "$both" ]]; then
          printf '%s\n' "$both" > "$DIR/merge-files"
          for parent in "$p1" "$p2"; do
            printf '# merge %s against parent %s\n' "$(git rev-parse --short "$c")" "$(git rev-parse --short "$parent")" >> "$DIR/delta.patch"
            $GIT_DIFF "$parent" "$c" -- $(cat "$DIR/merge-files") >> "$DIR/delta.patch"
          done
          rm -f "$DIR/merge-files"
        fi
      else
        git show --format= --no-color --no-ext-diff --no-show-signature "$c" >> "$DIR/delta.patch"
      fi
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
  is_num "$round" || die "the ledger's round= is not a number ($round); run begin again"
  [[ "$round" -ge 1 ]] || refuse "run \`gate-ledger.sh round\` first: it writes lode/tmp/gate/delta.patch, the diff the agents review"
  tier="$(lget tier)"; cap="$(lget cap)"
  is_num "$cap" || die "the ledger's cap= is not a number ($cap); run begin again"
  name="${agent#lode:}"
  case "$tier" in
    light) set_="gate-tests gate-rules gate-parser" ;;
    *) set_="gate-tests gate-rules gate-parser gate-correctness gate-claims" ;;
  esac
  in_set=0
  for a in $set_; do [[ "$a" == "$name" ]] && in_set=1; done
  [[ "$in_set" == 1 ]] || refuse "$name is not in the $tier gate (its agents: $set_)"
  declared="$(declared_model "$name")"
  if [[ -n "$model" && -n "$declared" && "$declared" != inherit && "$declared" != "$model" ]]; then
    refuse "$name declares model: $declared; spawning it on $model is not allowed — drop the model override"
  fi
  percap="$cap"
  [[ "$tier" == critical && "$name" == gate-correctness ]] && percap=$((cap * 2))
  count="$(spawn_count "$name")"
  if [[ "$count" -ge "$percap" ]]; then
    refuse "spawn $((count + 1)) of $name exceeds the cap of $percap at tier $tier (the round limit): record the pass with the remaining P2s deferred (\`gate-ledger.sh pass --deferred N\`), or report the P1 and record nothing"
  fi
  lappend "spawned=$round:$name:${model:-$declared}"   # one appended line: parallel spawns of a fan-out do not race"
  ;;

pass)
  deferred=0; p1=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deferred) need_value "$@"; deferred="$2"; shift 2 ;;
      --p1) need_value "$@"; p1="$2"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  is_num "$deferred" || die "--deferred must be a whole number"
  is_num "$p1" || die "--p1 must be a whole number"
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
  usage
  ;;
esac
