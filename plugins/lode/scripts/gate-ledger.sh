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
#       the last round: each non-merge commit's own diff, and for a merge commit the diff from
#       each parent to the merge result over every file except those only the other side
#       changed since the two diverged — what the merge did that its other side does not
#       explain. A clean merge of files the branch never touched leaves nothing; a hand-
#       combined resolution, an edit made inside the merge, a file the merge added, a
#       resolution under a renamed file, and every one-sided resolution (--ours, --theirs,
#       -s ours, checkout <side> -- <file>) show as the hunks they are, next to each side's
#       own hunk in a file both touched. Only the first two parents of a merge are read.
#       Prints round=, range=, delta_lines= (hunk lines; the "# merge" annotations are not
#       counted), tier=, cap=, agents= (the comma-separated names this round may spawn),
#       same= (1 when delta.patch and diff.patch are byte-identical, else 0).
#       agents= is the intersection of the tier's set with the lenses the delta has work
#       for: rules on every non-empty delta (a rename-only delta included); tests unless the
#       delta is prose-only (a source change with no test is exactly what its coverage audit
#       reports); parser when an added line looks like a regex or scanner; correctness when
#       the delta is not prose-only (standard and critical); claims when the delta has prose
#       (standard and critical, and also light — a docs or lode PR is what claims is for).
#       Fails (exit 1) when the base has no merge base with HEAD, so a shallow clone never
#       reads as "nothing to review".
#   gate-ledger.sh spawn <lode:gate-agent> [<model>]
#       The decision behind pre-agent-gate.sh: exit 0 and record the spawn (count and append
#       under a lock file, so a fan-out's parallel spawns — of different agents or the same
#       one — all count against the cap; a lock nobody releases within five seconds is a
#       refusal, and one older than a minute or two is taken over), or exit 3 with the reason (no ledger, another
#       branch, no round yet, an agent not in this round's agents= (or, if that key is
#       missing — a 0.4 ledger — not in the tier's set), a model override on an agent that
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
export LC_ALL=C   # byte-wise tr, sort, comm and grep: a path is bytes, whatever the caller's locale

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "gate-ledger: not inside a git repository" >&2; exit 1; }
cd "$ROOT" || exit 1                 # every path below is repo-relative, whatever directory the caller sat in
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
  awk 'NR == 1 { sub(/^\357\273\277/, ""); if ($0 !~ /^---[ \t\r]*$/) exit; next }
       /^---[ \t\r]*$/ { exit }
       /^model:/ { sub(/^model:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/["\047\r]/, ""); sub(/[ \t]+$/, ""); print; exit }' "$AGENTS_DIR/$1.md" 2>/dev/null
}
name_list() { # name_list <a> <b> — the files that differ, one per line, sorted; loud on a name with a newline
  local n z
  z="$($GIT_DIFF --name-only --no-renames -z "$1" "$2" | tr -dc '\0' | wc -c | tr -d ' ')"
  $GIT_DIFF --name-only --no-renames -z "$1" "$2" | tr '\0' '\n' > "$DIR/names"
  n="$(wc -l < "$DIR/names" | tr -d ' ')"
  [[ "$n" == "$z" ]] || die "a file name between $1 and $2 contains a newline; the merge delta cannot be built"
  LC_ALL=C sort "$DIR/names"; rm -f "$DIR/names"
}
agents_summary() { # "gate-rules x3 (sonnet), gate-tests x1 (sonnet)"
  [[ -f "$LEDGER" ]] || return 0
  sed -n 's/^spawned=[0-9]*://p' "$LEDGER" | sort | uniq -c | awk '{
    split($2, a, ":"); s = a[1] " x" $1; if (a[2] != "") s = s " (" a[2] ")";
    out = (out == "" ? s : out ", " s) } END { printf "%s", out }'
}
# Paths in delta.patch: --- a/foo / +++ b/foo, quoted when git quotes them. /dev/null is a
# creation or deletion, not a path. Classify from this round's delta, not the whole branch.
delta_paths() {
  sed -n \
    -e 's|^--- a/||p' \
    -e 's|^+++ b/||p' \
    -e 's|^--- "a/\(.*\)"$|\1|p' \
    -e 's|^+++ "b/\(.*\)"$|\1|p' \
    "$DIR/delta.patch" | sed 's/	.*$//' | grep -vx '/dev/null' | grep -v '^$' | LC_ALL=C sort -u
}
is_prose_path() {
  case "$1" in
    *.md|*.mdx|*.txt|*.rst|*.adoc) return 0 ;;
    LICENSE|LICENSE.*|COPYING|COPYING.*) return 0 ;;
    CHANGELOG|CHANGELOG.*|README|README.*) return 0 ;;
    .gitignore|.gitattributes|.editorconfig|.mailmap) return 0 ;;
    lode|lode/*|docs|docs/*) return 0 ;;
    .claude/rules/*|.claude/commands/*|.claude/references/*) return 0 ;;   # settings.json and hook scripts are not prose
  esac
  return 1
}
is_test_path() {
  case "$1" in
    test/*|*/test/*|spec/*|*/spec/*|tests/*|*/tests/*|features/*|*/features/*) return 0 ;;
    *_test.*|*_spec.*|*.test.*|*.spec.*) return 0 ;;
  esac
  return 1
}
PARSE_RE='^\+.*(%r\{|/\\[A-Za-z]|=~|\.match\(|\.scan\(|StringScanner|\.split\(|Regexp|re\.compile|new RegExp)'
# classify_agents <tier> <delta_lines> — stdout is the comma-separated names this round may spawn, or empty
classify_agents() {
  local tier="$1" p has_test=0 has_prose=0 has_source=0 has_parse=0 any=0
  [[ "${2:-0}" -gt 0 ]] && any=1   # a rename-only delta has hunk lines but no ---/+++ paths; rules still reads it
  local allow_corr=1 allow_claims=1 out=""
  delta_paths > "$DIR/delta-paths"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    any=1
    is_test_path "$p" && has_test=1
    if is_prose_path "$p"; then has_prose=1; else has_source=1; fi
  done < "$DIR/delta-paths"
  rm -f "$DIR/delta-paths"
  if grep -qE "$PARSE_RE" "$DIR/delta.patch" 2>/dev/null; then has_parse=1; any=1; fi
  case "$tier" in
    light) allow_corr=0; allow_claims=0; [[ "$has_prose" == 1 ]] && allow_claims=1 ;;
  esac
  if [[ "$has_test" == 1 || "$has_source" == 1 ]]; then out=gate-tests; fi   # not on a prose-only delta
  if [[ "$any" == 1 ]]; then if [[ -n "$out" ]]; then out="$out,gate-rules"; else out=gate-rules; fi; fi
  if [[ "$has_parse" == 1 ]]; then if [[ -n "$out" ]]; then out="$out,gate-parser"; else out=gate-parser; fi; fi
  if [[ "$has_source" == 1 && "$allow_corr" == 1 ]]; then if [[ -n "$out" ]]; then out="$out,gate-correctness"; else out=gate-correctness; fi; fi
  if [[ "$has_prose" == 1 && "$allow_claims" == 1 ]]; then if [[ -n "$out" ]]; then out="$out,gate-claims"; else out=gate-claims; fi; fi
  printf '%s' "$out"
}
tier_set() { # stdout: space-separated names the tier itself allows (0.4 fail-open)
  case "$1" in
    light) printf '%s' "gate-tests gate-rules gate-parser" ;;
    *) printf '%s' "gate-tests gate-rules gate-parser gate-correctness gate-claims" ;;
  esac
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
  mkdir -p "$DIR"; rm -f "$DIR/spawn.lock"   # a new invocation: no spawn of the old one can still hold it
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
      parents="$(git rev-list --parents -n 1 "$c" | cut -s -d' ' -f2-)"   # empty for a root commit
      if [[ "$parents" == *" "* ]]; then
        # A merge. When unsure, include: a hunk the reviewer did not need costs a minute, a
        # hunk they never saw is a pass stamped on unreviewed code. From each parent, the diff
        # to the result over every file except those only the other side changed since the
        # two diverged: what this merge did that its other side does not explain. A clean
        # merge leaves nothing (each side's files are excluded from the other's view); a
        # resolution, an edit made inside the merge, a file it added, and every one-sided
        # resolution — --ours, --theirs, -s ours, checkout <side> -- <file> — are hunks.
        p1="${parents%% *}"; p2="${parents#* }"; p2="${p2%% *}"
        mb="$(git merge-base "$p1" "$p2" 2>/dev/null || true)"
        name_list "${mb:-$p1}" "$p1" > "$DIR/side1"
        name_list "${mb:-$p2}" "$p2" > "$DIR/side2"
        comm -23 "$DIR/side2" "$DIR/side1" > "$DIR/only2"   # files only the base side changed: not p1's business
        comm -23 "$DIR/side1" "$DIR/side2" > "$DIR/only1"   # files only the branch side changed: not p2's business
        for parent in "$p1" "$p2"; do
          if [[ "$parent" == "$p1" ]]; then excl="$DIR/only2"; else excl="$DIR/only1"; fi
          name_list "$parent" "$c" > "$DIR/changed"
          comm -23 "$DIR/changed" "$excl" > "$DIR/merge-files"
          if [[ -s "$DIR/merge-files" ]]; then
            files=()
            while IFS= read -r f; do files[${#files[@]}]="$f"; done < "$DIR/merge-files"
            # every listed file differs from this parent, so the diff below is never empty
            printf '# merge %s against parent %s\n' "$(git rev-parse --short "$c")" "$(git rev-parse --short "$parent")" >> "$DIR/delta.patch"
            git --literal-pathspecs diff --no-color --no-ext-diff "$parent" "$c" -- "${files[@]}" >> "$DIR/delta.patch" || die "git diff $(git rev-parse --short "$parent")..$(git rev-parse --short "$c") failed; the merge delta cannot be built"
          fi
        done
        rm -f "$DIR/side1" "$DIR/side2" "$DIR/only1" "$DIR/only2" "$DIR/changed" "$DIR/merge-files"
      else
        git show --format= --no-color --no-ext-diff --no-show-signature "$c" >> "$DIR/delta.patch"
      fi
    done
  fi
  lines="$(grep -vc '^# merge ' "$DIR/delta.patch" || true)"   # hunk lines; the annotations are not reviewable content
  agents="$(classify_agents "$tier" "$lines")"
  same=0
  if cmp -s "$DIR/delta.patch" "$DIR/diff.patch"; then same=1; fi
  lset round "$next"; lset seen "$head"; lset "delta.$next" "$lines"; lset "kind.$next" "$kind"
  lset "agents.$next" "$agents"; lset "same.$next" "$same"
  printf 'round=%s\nrange=%s\ndelta_lines=%s\ntier=%s\ncap=%s\nagents=%s\nsame=%s\n' "$next" "$range" "$lines" "$tier" "$cap" "$agents" "$same"
  ;;

spawn)
  agent="${1:-}"; model="$(printf '%s' "${2:-}" | tr '\n\r' '  ')"
  [[ -n "$agent" ]] || die "spawn needs the agent name"
  need_ledger
  round="$(lget round)"; round="${round:-0}"
  is_num "$round" || die "the ledger's round= is not a number ($round); run begin again"
  [[ "$round" -ge 1 ]] || refuse "run \`gate-ledger.sh round\` first: it writes lode/tmp/gate/delta.patch, the diff the agents review"
  tier="$(lget tier)"; cap="$(lget cap)"
  is_num "$cap" || die "the ledger's cap= is not a number ($cap); run begin again"
  name="${agent#lode:}"
  in_set=0
  if grep -q "^agents\\.$round=" "$LEDGER"; then
    round_agents="$(lget "agents.$round")"
    case ",$round_agents," in *",$name,"*) in_set=1 ;; esac
    [[ "$in_set" == 1 ]] || refuse "$name is not in this round's agents ($round_agents)"
  else
    set_="$(tier_set "$tier")"
    for a in $set_; do [[ "$a" == "$name" ]] && in_set=1; done
    [[ "$in_set" == 1 ]] || refuse "$name is not in the $tier gate (its agents: $set_)"
  fi
  [[ -f "$AGENTS_DIR/$name.md" ]] || die "no agent definition at $AGENTS_DIR/$name.md; the plugin install is incomplete"
  declared="$(declared_model "$name")"
  if [[ -n "$model" && -n "$declared" && "$declared" != inherit && "$declared" != "$model" ]]; then
    refuse "$name declares model: $declared; spawning it on $model is not allowed — drop the model override"
  fi
  percap="$cap"
  [[ "$tier" == critical && "$name" == gate-correctness ]] && percap=$((cap * 2))
  # The count and the append are one step under a lock file (noclobber is an atomic
  # O_EXCL create; bash 3.2 has no flock), so a fan-out's parallel spawns — of different
  # agents or of the same one — all count. A lock nobody releases is a refusal, not an
  # uncounted spawn: retrying is cheap and an uncounted spawn is what the cap exists to stop.
  lock="$DIR/spawn.lock"; tries=0
  until ( set -o noclobber; printf '%s\n' "$$" > "$lock" ) 2>/dev/null; do
    tries=$((tries + 1))
    if [[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then rm -f "$lock"; fi   # older than a minute or two: its holder is gone
    [[ "$tries" -le 50 ]] || refuse "another spawn has held $lock for five seconds; retry, or remove the file if no gate agent is being spawned"
    sleep 0.1
  done
  count="$(spawn_count "$name")"
  if [[ "$count" -ge "$percap" ]]; then
    rm -f "$lock"
    refuse "spawn $((count + 1)) of $name exceeds the cap of $percap at tier $tier (the round limit): record the pass with the remaining P2s deferred (\`gate-ledger.sh pass --deferred N\`), or report the P1 and record nothing"
  fi
  lappend "spawned=$round:$name:${model:-$declared}"
  rm -f "$lock"
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
