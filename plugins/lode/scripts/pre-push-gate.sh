#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Denies `git push` and `gh pr create` until
# /lode:gate has passed on the exact tree being pushed.
#
# Contract with Claude Code: exit 0 allows, exit 2 denies and stderr is shown
# to the agent. No JSON on stdout — Claude Code ignores it on exit 2 and
# rejects the wrong shape on exit 0, so the exit code carries the decision.
#
# Fail-open on anything unexpected (no git, no jq/ruby, unparseable input):
# a broken hook must never lock a collaborator out. Only an explicit
# "gate has not passed on this tree" denies.

set -u

allow() { exit 0; }
deny() { echo "[lode:gate] $1" >&2; exit 2; }

INPUT="$(cat || true)"
COMMAND=""; CWD=""
if command -v jq >/dev/null 2>&1; then
  COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .toolInput.command // ""' 2>/dev/null || true)"
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || true)"
elif command -v ruby >/dev/null 2>&1; then
  COMMAND="$(printf '%s' "$INPUT" | ruby -rjson -e 'begin; d=JSON.parse(STDIN.read); i=d["tool_input"]||d["toolInput"]||{}; print(i["command"].to_s); rescue StandardError; print ""; end' 2>/dev/null || true)"
  CWD="$(printf '%s' "$INPUT" | ruby -rjson -e 'begin; print(JSON.parse(STDIN.read)["cwd"].to_s); rescue StandardError; print ""; end' 2>/dev/null || true)"
fi
[[ -n "$COMMAND" ]] || allow

is_push=0
printf '%s' "$COMMAND" | grep -Eq '(^|[[:space:];|&(])git[[:space:]]+push([[:space:]]|$)' && is_push=1
printf '%s' "$COMMAND" | grep -Eq '(^|[[:space:];|&(])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' && is_push=1
[[ "$is_push" == "1" ]] || allow

# Emergency bypass. Accepted as an env var or as a prefix on the command
# itself, because some harnesses run hooks in a separate process.
if [[ "${LODE_SKIP_GATE:-}" == "1" ]] || printf '%s' "$COMMAND" | grep -Eq '(^[[:space:]]*|[;|&][[:space:]]*)LODE_SKIP_GATE=1[[:space:]]'; then
  echo "[lode:gate] LODE_SKIP_GATE=1 — allowing without the gate. Say why in the PR body." >&2
  allow
fi

# The repository being pushed is the one the command runs in, not the one
# the session opened: a session in repo A that runs `cd ../B && git push`
# is pushing B. Take the hook input's cwd, honour a leading `cd <dir>`
# in the command, and resolve that to a git toplevel. CLAUDE_PROJECT_DIR is
# only the fallback.
START="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
if [[ "$COMMAND" =~ ^[[:space:]]*cd[[:space:]]+([^[:space:]\;\&\|]+) ]]; then
  CDTARGET="${BASH_REMATCH[1]}"; CDTARGET="${CDTARGET/#\~/$HOME}"
  [[ "$CDTARGET" = /* ]] || CDTARGET="$START/$CDTARGET"
  [[ -d "$CDTARGET" ]] && START="$CDTARGET"
fi
ROOT="$(git -C "$START" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || allow

# A repo without a lode has not been seeded; the gate has nothing to read.
# Allow, but say so, so enabling the plugin before /lode:seed blocks nobody.
if [[ ! -d "$ROOT/lode" ]]; then
  echo "[lode:gate] no lode/ in this repo — allowing. Run /lode:seed to enable the gate." >&2
  allow
fi

TREE="$(git -C "$ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
[[ -n "$TREE" ]] || allow

MARKER="$ROOT/lode/tmp/gate-passed"
if [[ ! -f "$MARKER" ]]; then
  deny "no gate report for this branch. Run /lode:gate before pushing or opening a PR (bypass: LODE_SKIP_GATE=1, emergencies only)."
fi

PASSED_TREE="$(sed -n 's/^tree=//p' "$MARKER" | head -1)"
if [[ "$PASSED_TREE" != "$TREE" ]]; then
  deny "the gate passed on tree ${PASSED_TREE:0:12} but HEAD is tree ${TREE:0:12} — commits landed after the gate. Run /lode:gate again (bypass: LODE_SKIP_GATE=1, emergencies only)."
fi

allow
