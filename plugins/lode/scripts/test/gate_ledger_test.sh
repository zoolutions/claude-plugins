#!/usr/bin/env bash
# Tests for scripts/gate-ledger.sh and scripts/pre-agent-gate.sh. Plain bash, no framework.
# Run: bash plugins/lode/scripts/test/gate_ledger_test.sh
# Each case builds a throwaway git repo with a lode/ and a feature branch off main, runs the
# ledger subcommands and feeds the hook the JSON Claude Code sends a PreToolUse hook.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER="$HERE/../gate-ledger.sh"
HOOK="$HERE/../pre-agent-gate.sh"
PUSH_HOOK="$HERE/../pre-push-gate.sh"
TMP="$(mktemp -d)"; trap 'cd / && rm -rf "$TMP"' EXIT
fail=0; n=0

check() { # check <case> <expected> <actual>
  n=$((n+1))
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}
contains() { # contains <case> <needle> <haystack>
  n=$((n+1))
  if [[ "$3" == *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: expected to contain '$2', got '${3:0:300}'"; fail=1; fi
}
lacks() { # lacks <case> <needle> <haystack>
  n=$((n+1))
  if [[ "$3" != *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: expected not to contain '$2'"; fail=1; fi
}

G() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# make_repo <name> [tier-default] — leaves the path in $REPO, on branch feat with one commit past main
make_repo() {
  REPO="$TMP/$1"; mkdir -p "$REPO/lode"; cd "$REPO"
  G init -q -b main
  printf '# Workflow profile\n\n## Rigor\n\n- Default: %s\n\n| Paths | Tier |\n|---|---|\n| `money/**` | critical |\n' "${2:-standard}" > lode/workflow.md
  printf 'lode/tmp/\n' > .gitignore
  echo base > README.md; mkdir -p t; echo 'echo t' > t/a_test.sh
  G add -A && G commit -qm base
  G switch -qc feat
  echo feature > feature.txt; G add -A && G commit -qm 'feat: one'
}
ledger_get() { sed -n "s/^$1=//p" lode/tmp/gate/ledger | head -1; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }
hook_json() { # hook_json <subagent_type> [model]
  if [[ -n "${2:-}" ]]; then
    printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"%s","model":"%s","prompt":"x"}}' "$PWD" "$1" "$2"
  else
    printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"%s","prompt":"x"}}' "$PWD" "$1"
  fi
}
spawn() { hook_json "$@" | bash "$HOOK" 2>"$TMP/err"; echo $?; }
spawn_err() { hook_json "$@" | bash "$HOOK" 2>&1 >/dev/null; }

# --- begin and the first round ------------------------------------------------------------
make_repo one
out=$(bash "$LEDGER" begin main 2>/dev/null)
check "begin: tier from the profile" standard "$(field "$out" tier)"
check "begin: cap at standard is 3" 3 "$(field "$out" cap)"
check "begin: first invocation" 1 "$(field "$out" invocation)"
check "begin: round is 0 until round runs" 0 "$(ledger_get round)"
check "begin: ledger names the branch" feat "$(ledger_get branch)"
out=$(bash "$LEDGER" round 2>/dev/null)
check "round 1: round counter" 1 "$(field "$out" round)"
check "round 1: full range on a branch never seen" "main...HEAD" "$(field "$out" range)"
check "round 1: delta is the full diff" "$(cat lode/tmp/gate/diff.patch)" "$(cat lode/tmp/gate/delta.patch)"
check "round 1: seen is HEAD" "$(git rev-parse HEAD)" "$(ledger_get seen)"

# --- round 2 reviews only the fix ---------------------------------------------------------
echo fixed > fix.txt; G add -A && G commit -qm 'fix: two'
out=$(bash "$LEDGER" round 2>/dev/null)
check "round 2: round counter" 2 "$(field "$out" round)"
contains "round 2: delta has the fix" "+fixed" "$(cat lode/tmp/gate/delta.patch)"
lacks "round 2: delta lacks round 1's content" "+feature" "$(cat lode/tmp/gate/delta.patch)"
contains "round 2: full diff still has everything" "+feature" "$(cat lode/tmp/gate/diff.patch)"
check "round 2: delta_lines is the patch length" "$(wc -l < lode/tmp/gate/delta.patch | tr -d ' ')" "$(field "$out" delta_lines)"

# --- round limit -----------------------------------------------------------------------------
echo three > three.txt; G add -A && G commit -qm 'fix: three'
bash "$LEDGER" round >/dev/null 2>&1
echo four > four.txt; G add -A && G commit -qm 'fix: four'
out=$(bash "$LEDGER" round 2>&1 >/dev/null); rc=$?
check "round 4 at standard: refused" 3 "$rc"
contains "round 4: says what to do" "deferred" "$out"
check "round 4: counter stays at 3" 3 "$(ledger_get round)"

# --- a clean merge of the base is an empty delta -------------------------------------------
make_repo two
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
G switch -q main; echo more >> README.md; G commit -qam 'main moves'; G switch -q feat
G merge -q --no-edit main
out=$(bash "$LEDGER" round 2>/dev/null)
check "clean merge: delta is empty" 0 "$(field "$out" delta_lines)"
contains "clean merge: full diff excludes the base's own change" "+feature" "$(cat lode/tmp/gate/diff.patch)"
lacks "clean merge: full diff excludes the base's own change (2)" "+more" "$(cat lode/tmp/gate/diff.patch)"

# --- a resolved conflict is only the resolution ---------------------------------------------
make_repo three
echo 'left' > shared.txt; echo other > other.txt; G add -A && G commit -qm 'feat: shared'
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
G switch -q main; echo 'right' > shared.txt; echo unrelated > unrelated.txt; G add -A && G commit -qm 'main: shared'; G switch -q feat
G merge -q --no-edit main >/dev/null 2>&1 || true
echo 'both' > shared.txt; G add shared.txt && G commit -qm 'merge main'
out=$(bash "$LEDGER" round 2>/dev/null)
contains "resolved conflict: delta holds the resolution" "both" "$(cat lode/tmp/gate/delta.patch)"
lacks "resolved conflict: delta lacks the base's unrelated file" "unrelated" "$(cat lode/tmp/gate/delta.patch)"
lacks "resolved conflict: delta lacks round 1's file" "other" "$(cat lode/tmp/gate/delta.patch)"

# --- a rewritten branch falls back to the full diff -----------------------------------------
make_repo four
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
G reset -q --hard main; echo rewritten > r.txt; G add -A && G commit -qm 'rewritten'
out=$(bash "$LEDGER" round 2>"$TMP/err")
check "rewritten branch: full range" "main...HEAD" "$(field "$out" range)"
contains "rewritten branch: reason on stderr" "not an ancestor" "$(cat "$TMP/err")"

# --- a second begin resets the counters and keeps reviewed ---------------------------------
make_repo five
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
check "spawn before begin 2: allowed" 0 "$(spawn lode:gate-rules)"
bash "$LEDGER" pass >/dev/null 2>&1
first_reviewed="$(ledger_get reviewed)"
out=$(bash "$LEDGER" begin main 2>/dev/null)
check "begin 2: invocation 2" 2 "$(field "$out" invocation)"
check "begin 2: reviewed kept" "$first_reviewed" "$(ledger_get reviewed)"
check "begin 2: spawn records reset" 0 "$(grep -c "^spawned=" lode/tmp/gate/ledger || true)"
check "begin 2: round reset" 0 "$(ledger_get round)"
echo after > after.txt; G add -A && G commit -qm 'after the pass'
bash "$LEDGER" begin main >/dev/null 2>&1; out=$(bash "$LEDGER" round 2>/dev/null)
contains "begin 2: seen carried, the delta is the commit since the last round" "+after" "$(cat lode/tmp/gate/delta.patch)"
lacks "begin 2: seen carried, the delta lacks the first round's content" "+feature" "$(cat lode/tmp/gate/delta.patch)"
check "begin 2: seen carried, range is a delta" "$(git rev-parse HEAD~1)..HEAD" "$(field "$out" range)"

# --- the hook: caps, tiers, models ---------------------------------------------------------
make_repo six
check "hook: no ledger yet denies" 2 "$(spawn lode:gate-rules)"
contains "hook: no ledger names begin" "begin" "$(spawn_err lode:gate-rules)"
contains "hook: no ledger is its own reason" "no gate ledger" "$(spawn_err lode:gate-rules)"
bash "$LEDGER" begin main >/dev/null 2>&1
check "hook: round 0 denies" 2 "$(spawn lode:gate-rules)"
contains "hook: round 0 names round" "round" "$(spawn_err lode:gate-rules)"
bash "$LEDGER" round >/dev/null 2>&1
check "hook: non-gate agent allowed" 0 "$(spawn Explore)"
check "hook: 1st gate-rules allowed" 0 "$(spawn lode:gate-rules)"
check "hook: 2nd gate-rules allowed" 0 "$(spawn lode:gate-rules)"
check "hook: 3rd gate-rules allowed" 0 "$(spawn lode:gate-rules)"
check "hook: 4th gate-rules denied at standard" 2 "$(spawn lode:gate-rules)"
contains "hook: 4th names the cap" "cap of 3" "$(spawn_err lode:gate-rules)"
contains "hook: 4th says what to do" "deferred" "$(spawn_err lode:gate-rules)"
check "hook: records stop at the cap" 3 "$(grep -c "^spawned=1:gate-rules:" lode/tmp/gate/ledger)"
check "hook: gate-claims allowed at standard" 0 "$(spawn lode:gate-claims)"
check "hook: model override on a sonnet agent denied" 2 "$(spawn lode:gate-claims opus)"
contains "hook: model denial names sonnet" "sonnet" "$(spawn_err lode:gate-claims opus)"
check "hook: same model as declared allowed" 0 "$(spawn lode:gate-claims sonnet)"
check "hook: model override on an inherit agent allowed" 0 "$(spawn lode:gate-correctness opus)"
check "hook: spawns are recorded" 3 "$(grep -c '^spawned=1:gate-rules' lode/tmp/gate/ledger)"
contains "hook: model recorded" "spawned=1:gate-claims:sonnet" "$(cat lode/tmp/gate/ledger)"

make_repo light light
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
check "light: cap 1" 1 "$(ledger_get cap)"
check "light: 1st gate-tests allowed" 0 "$(spawn lode:gate-tests)"
check "light: 2nd gate-tests denied" 2 "$(spawn lode:gate-tests)"
check "light: gate-claims outside the set denied" 2 "$(spawn lode:gate-claims)"
contains "light: denial names the tier" "light" "$(spawn_err lode:gate-claims)"
check "light: gate-parser allowed" 0 "$(spawn lode:gate-parser)"
out=$(bash "$LEDGER" round 2>&1 >/dev/null); check "light: round 2 refused" 3 "$?"

make_repo crit critical
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
check "critical: cap 5" 5 "$(ledger_get cap)"
for i in 1 2 3 4 5; do spawn lode:gate-rules >/dev/null; done
check "critical: 6th gate-rules denied" 2 "$(spawn lode:gate-rules)"
for i in 1 2 3 4 5 6; do spawn lode:gate-correctness >/dev/null; done
check "critical: 7th gate-correctness allowed (two per round)" 0 "$(spawn lode:gate-correctness)"

make_repo rounds
out=$(bash "$LEDGER" begin main --rounds 2 2>/dev/null)
check "--rounds 2: cap lowered" 2 "$(field "$out" cap)"
bash "$LEDGER" round >/dev/null 2>&1
spawn lode:gate-rules >/dev/null; spawn lode:gate-rules >/dev/null
check "--rounds 2: 3rd spawn denied" 2 "$(spawn lode:gate-rules)"
out=$(bash "$LEDGER" begin main --tier light --why "docs only" 2>/dev/null)
check "--tier light: tier overridden" light "$(field "$out" tier)"
check "--tier light: reason kept" "docs only" "$(ledger_get override)"
out=$(bash "$LEDGER" begin main --tier light 2>&1 >/dev/null); rc=$?
check "--tier light without --why: refused" 1 "$rc"
out=$(bash "$LEDGER" begin main --tier critical 2>/dev/null)
check "--tier critical: raising is free" critical "$(field "$out" tier)"

# --- the hook fails open like the push hook --------------------------------------------------
make_repo open
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
printf 'not json' | bash "$HOOK" 2>/dev/null; check "hook: unparseable input allows" 0 "$?"
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"ls"}}' "$PWD" | bash "$HOOK" 2>/dev/null; check "hook: another tool allows" 0 "$?"
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"subagent_type":"lode:gate-rules"}}' "$PWD" | bash "$HOOK" 2>/dev/null; check "hook: another tool with a gate-looking input allows" 0 "$?"
BIN="$TMP/bin"; mkdir -p "$BIN"; ln -sf "$(command -v git)" "$BIN/git"; ln -sf "$(command -v bash)" "$BIN/bash"
ln -sf "$(command -v sed)" "$BIN/sed"; ln -sf "$(command -v grep)" "$BIN/grep"; ln -sf "$(command -v cat)" "$BIN/cat"
hook_json lode:gate-rules | env PATH="$BIN" "$BIN/bash" "$HOOK" 2>/dev/null; check "hook: no jq and no ruby allows" 0 "$?"
for i in 1 2 3; do spawn lode:gate-rules >/dev/null; done
LODE_SKIP_GATE=1 hook_json lode:gate-rules | LODE_SKIP_GATE=1 bash "$HOOK" 2>"$TMP/err"; check "hook: LODE_SKIP_GATE=1 allows past the cap" 0 "$?"
contains "hook: LODE_SKIP_GATE=1 says so" "LODE_SKIP_GATE" "$(cat "$TMP/err")"
G switch -qc other
check "hook: ledger for another branch denies" 2 "$(spawn lode:gate-rules)"
contains "hook: names the ledger's branch" "feat" "$(spawn_err lode:gate-rules)"
G switch -q feat
mkdir -p "$TMP/nolode" && cd "$TMP/nolode" && G init -q -b main && echo x > x && G add -A && G commit -qm x
printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"lode:gate-rules"}}' "$PWD" | bash "$HOOK" 2>"$TMP/err"; check "hook: no lode/ allows" 0 "$?"
contains "hook: no lode/ says so" "no lode/" "$(cat "$TMP/err")"

# --- pass writes the marker the push hook reads --------------------------------------------
make_repo pass
bash "$LEDGER" begin main >/dev/null 2>&1
bash "$LEDGER" pass >/dev/null 2>&1; check "pass: refused before any round" 3 "$?"
check "pass: no marker before any round" 0 "$( [[ -f lode/tmp/gate-passed ]] && echo 1 || echo 0 )"
bash "$LEDGER" round >/dev/null 2>&1
spawn lode:gate-rules >/dev/null; spawn lode:gate-tests >/dev/null
echo dirty > dirty.txt
bash "$LEDGER" pass >/dev/null 2>&1; check "pass: dirty tree refused" 3 "$?"
rm dirty.txt
bash "$LEDGER" pass --p1 1 >/dev/null 2>&1; check "pass: an open P1 refused" 3 "$?"
bash "$LEDGER" pass --p1 "1-1" >/dev/null 2>&1; check "pass: --p1 must be a whole number" 1 "$?"
bash "$LEDGER" pass --p1 >/dev/null 2>&1; check "pass: --p1 without a value exits" 1 "$?"
bash "$LEDGER" pass --deferred x >/dev/null 2>&1; check "pass: --deferred must be a whole number" 1 "$?"
check "pass: no marker after a refusal" 0 "$( [[ -f lode/tmp/gate-passed ]] && echo 1 || echo 0 )"
bash "$LEDGER" pass --deferred 2 >/dev/null 2>&1; check "pass: exit 0" 0 "$?"
marker="$(cat lode/tmp/gate-passed)"
check "pass: tree is HEAD^{tree}" "$(git rev-parse 'HEAD^{tree}')" "$(field "$marker" tree)"
check "pass: tier" standard "$(field "$marker" tier)"
check "pass: rounds" 1 "$(field "$marker" rounds)"
check "pass: deferred" 2 "$(field "$marker" deferred)"
contains "pass: agents by name and model" "gate-rules x1 (sonnet)" "$(field "$marker" agents)"
contains "pass: every spawned agent is listed" "gate-tests x1 (sonnet)" "$(field "$marker" agents)"
check "pass: report key" "lode/tmp/gate/report.md" "$(field "$marker" report)"
check "pass: at is a UTC timestamp" 1 "$( [[ "$(field "$marker" at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo 1 || echo 0 )"
check "pass: reviewed is HEAD" "$(git rev-parse HEAD)" "$(ledger_get reviewed)"
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git push"}}' "$PWD" | bash "$PUSH_HOOK" 2>/dev/null; check "push hook: allows on the passed tree" 0 "$?"
echo later > later.txt; G add -A && G commit -qm later
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git push"}}' "$PWD" | bash "$PUSH_HOOK" 2>/dev/null; check "push hook: denies after a later commit" 2 "$?"
out=$(bash "$LEDGER" show 2>/dev/null)
contains "show: prints Spent" "Spent" "$out"
contains "show: names the agents" "gate-rules" "$out"

# --- parallel spawns (the gate's one-message fan-out) do not race -------------------------
make_repo par
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
for a in gate-rules gate-tests gate-parser gate-correctness gate-claims; do hook_json "lode:$a" | bash "$HOOK" 2>/dev/null & done; wait
check "parallel: five spawns recorded" 5 "$(grep -c '^spawned=1:' lode/tmp/gate/ledger)"
check "parallel: ledger keys intact" feat "$(ledger_get branch)"
check "parallel: cap intact" 3 "$(ledger_get cap)"
check "parallel: a later spawn still counts" 0 "$(spawn lode:gate-rules)"
check "parallel: the cap still holds" 2 "$( spawn lode:gate-rules >/dev/null; spawn lode:gate-rules )"
make_repo same-agent
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
for i in 1 2 3 4 5 6; do hook_json lode:gate-rules | bash "$HOOK" 2>/dev/null & done; wait
check "parallel: six spawns of one agent at cap 3 record exactly 3" 3 "$(grep -c '^spawned=1:gate-rules:' lode/tmp/gate/ledger)"
check "parallel: the lock is released" 0 "$( [[ -e lode/tmp/gate/spawn.lock ]] && echo 1 || echo 0 )"
echo 99999 > lode/tmp/gate/spawn.lock && touch -t 202001010000 lode/tmp/gate/spawn.lock
check "parallel: a stale lock is taken over" 2 "$(spawn lode:gate-rules)"
echo 99999 > lode/tmp/gate/spawn.lock
check "parallel: a fresh lock nobody releases is a refusal, not an uncounted spawn" 2 "$(spawn lode:gate-tests)"
contains "parallel: the refusal names the lock" "spawn.lock" "$(spawn_err lode:gate-tests)"
check "parallel: nothing recorded while the lock was held" 0 "$(grep -c '^spawned=1:gate-tests:' lode/tmp/gate/ledger || true)"
bash "$LEDGER" begin main >/dev/null 2>&1
check "begin: clears a leftover lock" 0 "$( [[ -e lode/tmp/gate/spawn.lock ]] && echo 1 || echo 0 )"

# --- the frontmatter reader --------------------------------------------------------------
make_repo fm
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
AG="$TMP/agents"; mkdir -p "$AG"
printf -- '---\nname: gate-rules\nmodel: "sonnet"   # pinned\r\n---\n\nmodel: opus\n' > "$AG/gate-rules.md"
printf -- '---\nname: gate-claims\n---\nmodel: sonnet\n' > "$AG/gate-claims.md"
printf -- 'not frontmatter\nmodel: sonnet\n' > "$AG/gate-tests.md"
printf -- '---\r\nname: gate-parser\r\nmodel: sonnet\r\n---\r\n' > "$AG/gate-parser.md"
printf -- '\357\273\277--- \nname: gate-correctness\nmodel: sonnet\n---\n' > "$AG/gate-correctness.md"
check "frontmatter: quoted, commented, CRLF value reads as sonnet" 0 "$(LODE_AGENTS_DIR=$AG spawn lode:gate-rules sonnet)"
check "frontmatter: override still denied" 2 "$(LODE_AGENTS_DIR=$AG spawn lode:gate-rules opus)"
check "frontmatter: a body model: line is not a declaration" 0 "$(LODE_AGENTS_DIR=$AG spawn lode:gate-claims opus)"
check "frontmatter: no frontmatter, no declaration" 0 "$(LODE_AGENTS_DIR=$AG spawn lode:gate-tests opus)"
check "frontmatter: CRLF on the opening fence still declares" 2 "$(LODE_AGENTS_DIR=$AG spawn lode:gate-parser opus)"
check "frontmatter: a BOM and a trailing space on the opening fence still declare" 2 "$(LODE_AGENTS_DIR=$AG spawn lode:gate-correctness opus)"
check "spawn: a newline in the model cannot inject a key" 0 "$(spawn lode:gate-correctness "$(printf 'opus\ncap=99')")"
check "spawn: the model is flattened" 3 "$(ledger_get cap)"
contains "frontmatter: recorded model is the unquoted word" "spawned=1:gate-rules:sonnet" "$(cat lode/tmp/gate/ledger)"

# --- option and value parsing --------------------------------------------------------------
make_repo opts
bash "$LEDGER" begin main --tier >/dev/null 2>&1; check "begin: --tier without a value exits" 1 "$?"
bash "$LEDGER" begin main --rounds 0 >/dev/null 2>&1; check "begin: --rounds 0 refused" 1 "$?"
bash "$LEDGER" begin main --rounds abc >/dev/null 2>&1; check "begin: --rounds abc refused" 1 "$?"
bash "$LEDGER" begin main --tier light --why "$(printf 'docs only\ncap=99')" >/dev/null 2>&1
check "begin: a newline in --why cannot inject a key" 1 "$(ledger_get cap)"
check "begin: the reason is flattened" "docs only cap=99" "$(ledger_get override)"
bash "$LEDGER" round >/dev/null 2>&1
check "spawn: a multi-word agent name is refused" 2 "$(spawn 'lode:gate-rules gate-parser')"
contains "spawn: the multi-word refusal names the set" "not in the" "$(spawn_err 'lode:gate-rules gate-parser')"
check "spawn: an unknown gate agent is refused" 2 "$(spawn lode:gate-nope)"
check "spawn: a refused spawn is not recorded" 0 "$(grep -c "^spawned=" lode/tmp/gate/ledger || true)"
bash "$LEDGER" bogus 2>"$TMP/err"; check "usage: exit 1" 1 "$?"
lacks "usage: prints only the header" "set -u" "$(cat "$TMP/err")"
contains "usage: names the subcommands" "gate-ledger.sh pass" "$(cat "$TMP/err")"
G switch -qc 'topic/x=y'; bash "$LEDGER" begin main >/dev/null 2>&1
check "begin: a branch name with = and /" 'topic/x=y' "$(ledger_get branch)"
G switch -q --detach HEAD; bash "$LEDGER" begin main >/dev/null 2>&1
check "begin: detached HEAD" detached "$(ledger_get branch)"
G switch -q feat

# --- a corrupt ledger fails open at the hook -------------------------------------------------
make_repo corrupt
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
sed -i.bak 's/^cap=.*/cap=/' lode/tmp/gate/ledger
hook_json lode:gate-rules | bash "$HOOK" 2>"$TMP/err"; check "hook: an unreadable cap allows" 0 "$?"
contains "hook: says it could not decide" "could not decide" "$(cat "$TMP/err")"

# --- a one-sided resolution shows as what it is ----------------------------------------------
make_repo ours
printf 'a\nb-branch\n' > shared.txt; G add -A && G commit -qm 'feat: shared'
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
G switch -q main; printf 'a\nb-main\n' > shared.txt; echo u > unrelated.txt; G add -A && G commit -qm 'main: shared'; G switch -q feat
G merge -q --no-edit main >/dev/null 2>&1 || true
G checkout --ours shared.txt 2>/dev/null; G add shared.txt && G commit -qm 'merge main, ours'
out=$(bash "$LEDGER" round 2>/dev/null)
contains "ours: the delta shows the base's line going away" "-b-main" "$(cat lode/tmp/gate/delta.patch)"
lacks "ours: the delta lacks the base's unrelated file" "unrelated" "$(cat lode/tmp/gate/delta.patch)"
G switch -q main; printf 'a\nb-main\nc\n' > shared.txt; G commit -qam 'main: c'; G switch -q feat
G merge -q --no-edit main >/dev/null 2>&1 || true
G checkout --theirs shared.txt 2>/dev/null; G add shared.txt && G commit -qm 'merge main, theirs'
out=$(bash "$LEDGER" round 2>/dev/null)
contains "theirs: the delta shows the branch's line going away" "-b-branch" "$(cat lode/tmp/gate/delta.patch)"

# --- what the merge commit itself did is in the delta ----------------------------------------
make_repo evil
echo 'call old_name' > caller.txt; G add -A && G commit -qm 'feat: caller'
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
G switch -q main; echo 'def new_name' > helper.txt; G add -A && G commit -qm 'main: rename helper'; G switch -q feat
G merge -q --no-commit --no-edit main >/dev/null 2>&1
echo 'call new_name' > caller.txt; echo sneaky > sneaky.txt; G add -A && G commit -qm 'merge main, fix caller'
out=$(bash "$LEDGER" round 2>/dev/null)
contains "merge edit: the caller fix is in the delta" "call new_name" "$(cat lode/tmp/gate/delta.patch)"
contains "merge edit: the file the merge added is in the delta" "sneaky" "$(cat lode/tmp/gate/delta.patch)"
lacks "merge edit: the base's own new file is not" "def new_name" "$(cat lode/tmp/gate/delta.patch)"

make_repo same
printf 'a\nb\n' > shared.txt; G add -A && G commit -qm 'feat: shared'
G switch -q main; G merge -q --no-edit feat; G switch -q feat
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
printf 'a\nb-same\n' > shared.txt; G commit -qam 'feat: same edit'
G switch -q main; printf 'a\nb-same\n' > shared.txt; G commit -qam 'main: same edit'; G switch -q feat
G merge -q --no-edit main >/dev/null 2>&1
out=$(bash "$LEDGER" round 2>"$TMP/err")
check "identical edits on both sides: the merge adds nothing, the branch commit is the whole delta" "$(wc -l < lode/tmp/gate/delta.patch | tr -d ' ')" "$(field "$out" delta_lines)"
lacks "identical edits: no merge annotation" "# merge" "$(cat lode/tmp/gate/delta.patch)"
contains "identical edits: the branch's own commit is the delta" "+b-same" "$(cat lode/tmp/gate/delta.patch)"

make_repo spaces
printf 'a\nb-branch\n' > 'my file.txt'; printf 'x\ny-branch\n' > 'ä.txt'; mkdir app; printf 'p\nq-branch\n' > 'app/[id].txt'; printf 'sibling\n' > app/i.txt; G add -A && G commit -qm 'feat: odd names'
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
G switch -q main; printf 'a\nb-main\n' > 'my file.txt'; printf 'x\ny-main\n' > 'ä.txt'; mkdir -p app; printf 'p\nq-main\n' > 'app/[id].txt'; G add -A && G commit -qm 'main: odd names'; G switch -q feat
G merge -q --no-edit main >/dev/null 2>&1 || true
G checkout --ours -- 'my file.txt' 'ä.txt' 'app/[id].txt' 2>/dev/null; G add -A && G commit -qm 'merge, ours'
out=$(bash "$LEDGER" round 2>/dev/null)
contains "odd names: a path with a space reaches the delta" "-b-main" "$(cat lode/tmp/gate/delta.patch)"
contains "odd names: a non-ASCII path reaches the delta" "-y-main" "$(cat lode/tmp/gate/delta.patch)"
contains "odd names: a path with glob characters reaches the delta literally" "-q-main" "$(cat lode/tmp/gate/delta.patch)"

make_repo renamed
printf 'a\nb\n' > shared.txt; G add -A && G commit -qm 'feat: shared'
G switch -q main; G merge -q --no-edit feat; G switch -q feat
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
printf 'a\nb-branch\n' > shared.txt; G commit -qam 'feat: edit'
G switch -q main; G mv shared.txt renamed.txt; printf 'a\nb-main\n' > renamed.txt; G add -A && G commit -qm 'main: rename and edit'; G switch -q feat
G merge -q --no-edit main >/dev/null 2>&1 || true
printf 'a\nb-RESOLVED\n' > renamed.txt; G rm -q --cached shared.txt 2>/dev/null; rm -f shared.txt; G add -A && G commit -qm 'merge, resolved into the renamed file'
out=$(bash "$LEDGER" round 2>/dev/null)
contains "rename: the resolution reaches the delta" "b-RESOLVED" "$(cat lode/tmp/gate/delta.patch)"

make_repo subdir
printf 'a\nb-branch\n' > shared.txt; G add -A && G commit -qm 'feat: shared'
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
G switch -q main; printf 'a\nb-main\n' > shared.txt; G add -A && G commit -qm 'main: shared'; G switch -q feat
G merge -q --no-edit main >/dev/null 2>&1 || true
G checkout --ours shared.txt 2>/dev/null; G add shared.txt && G commit -qm 'merge, ours'
mkdir -p pkg/deep && (cd pkg/deep && bash "$LEDGER" round >/dev/null 2>&1)
contains "subdirectory: round sees the same delta" "-b-main" "$(cat lode/tmp/gate/delta.patch)"

make_repo unrelated
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
G switch -q --orphan island; echo island > feature.txt; G add -A && G commit -qm island; G switch -q feat
G merge -q --no-edit --allow-unrelated-histories island >/dev/null 2>&1 || true
echo resolved > feature.txt; G add -A && G commit -qm 'merge island'
out=$(bash "$LEDGER" round 2>/dev/null)
contains "unrelated histories: the resolution reaches the delta" "resolved" "$(cat lode/tmp/gate/delta.patch)"

make_repo noagent
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
mkdir -p "$TMP/noagents"
hook_json lode:gate-rules opus | LODE_AGENTS_DIR="$TMP/noagents" bash "$HOOK" 2>"$TMP/err"; check "hook: a missing agent definition allows, saying so" 0 "$?"
contains "hook: names the missing definition" "no agent definition" "$(cat "$TMP/err")"

# --- a merge that discards the other side's change shows it -------------------------------
make_repo sours
echo k-branch > only-branch.txt; G add -A && G commit -qm 'feat: only-branch'
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
G switch -q main; echo x-FIX > only-base.txt; G add -A && G commit -qm 'main: fix'; G switch -q feat
G merge -q -s ours --no-edit main
out=$(bash "$LEDGER" round 2>/dev/null)
contains "merge -s ours: the base's discarded fix is in the delta" "-x-FIX" "$(cat lode/tmp/gate/delta.patch)"
lacks "merge -s ours: the branch's own reviewed file is not" "k-branch" "$(cat lode/tmp/gate/delta.patch)"
check "merge -s ours: annotations are not counted" "$(grep -vc '^# merge ' lode/tmp/gate/delta.patch)" "$(field "$out" delta_lines)"
check "merge -s ours: one annotation, one parent" 1 "$(grep -c '^# merge ' lode/tmp/gate/delta.patch)"
G switch -q main; echo more > more.txt; G add -A && G commit -qm 'main: more'; G switch -q feat
G merge -q --no-commit --no-edit main >/dev/null 2>&1; G rm -q only-branch.txt; G commit -qm 'merge, dropping only-branch'
out=$(bash "$LEDGER" round 2>/dev/null)
contains "merge dropping the branch's file: shown as its removal" "-k-branch" "$(cat lode/tmp/gate/delta.patch)"
lacks "merge dropping the branch's file: the base's new file is not shown" "+more" "$(cat lode/tmp/gate/delta.patch)"

# --- no merge base is an error, not an empty delta -----------------------------------------
make_repo orphan
G switch -q --orphan lonely; echo o > o.txt; G add -A && G commit -qm lonely
bash "$LEDGER" begin main >/dev/null 2>&1; check "begin: no merge base refused" 1 "$?"

# --- the user's git config does not leak into the patches --------------------------------------
# (log.showSignature is handled by --no-show-signature but needs a signing key to exercise; not pinned here)
make_repo extdiff
printf '#!/bin/sh\necho EXTERNAL DIFF\n' > "$TMP/ext-diff.sh"; chmod +x "$TMP/ext-diff.sh"
G config diff.external "$TMP/ext-diff.sh"
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
lacks "diff.external: the full diff is git's own" "EXTERNAL DIFF" "$(cat lode/tmp/gate/diff.patch)"
echo fixed > fix.txt; G add -A && G commit -qm 'fix'
bash "$LEDGER" round >/dev/null 2>&1
lacks "diff.external: the delta is git's own" "EXTERNAL DIFF" "$(cat lode/tmp/gate/delta.patch)"
contains "diff.external: the delta still has the hunk" "+fixed" "$(cat lode/tmp/gate/delta.patch)"

# --- round checks the merge base itself ------------------------------------------------------
make_repo movedbase
bash "$LEDGER" begin main >/dev/null 2>&1
lonely="$(G commit-tree "$(git hash-object -t tree /dev/null)" -m lonely)"; G branch -f main "$lonely"   # an unrelated root, no checkout
bash "$LEDGER" round >/dev/null 2>&1; check "round: a base moved to an unrelated history is refused" 1 "$?"
check "round: nothing written on the refusal" 0 "$( [[ -f lode/tmp/gate/delta.patch ]] && echo 1 || echo 0 )"

# --- a different base starts the delta over ---------------------------------------------------
make_repo rebase
G branch -q develop main
bash "$LEDGER" begin main >/dev/null 2>&1; bash "$LEDGER" round >/dev/null 2>&1
echo two > two.txt; G add -A && G commit -qm two
out=$(bash "$LEDGER" begin develop 2>"$TMP/err"); bash "$LEDGER" round >/dev/null 2>&1
contains "base change: says so" "base changed" "$(cat "$TMP/err")"
contains "base change: full diff again" "+feature" "$(cat lode/tmp/gate/delta.patch)"

echo; echo "$n cases, fail=$fail"
exit $fail
