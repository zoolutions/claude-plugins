#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent). Refuses a `lode:gate-*` spawn the gate ledger does not
# allow: no ledger on this branch, no round run yet, an agent outside the tier's set, a model
# override on an agent whose definition declares one, or the per-agent cap (the tier's round
# limit) already reached. Every other Agent spawn is allowed untouched.
#
# Contract with Claude Code: exit 0 allows, exit 2 denies and stderr is shown to the agent.
# No JSON on stdout; the exit code carries the decision.
#
# Fail-open on anything unexpected (no git, no jq/ruby, unparseable input, no lode/): a
# broken hook must never stop a review. Only the ledger's explicit refusal denies.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
allow() { exit 0; }
deny() { echo "[lode:gate] $1" >&2; exit 2; }

INPUT="$(cat || true)"
TOOL=""; TYPE=""; MODEL=""; CWD=""
if command -v jq >/dev/null 2>&1; then
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)"
  TYPE="$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // .toolInput.subagent_type // ""' 2>/dev/null || true)"
  MODEL="$(printf '%s' "$INPUT" | jq -r '.tool_input.model // .toolInput.model // ""' 2>/dev/null || true)"
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || true)"
elif command -v ruby >/dev/null 2>&1; then
  TOOL="$(printf '%s' "$INPUT" | ruby -rjson -e 'begin; print(JSON.parse(STDIN.read)["tool_name"].to_s); rescue StandardError; print ""; end' 2>/dev/null || true)"
  TYPE="$(printf '%s' "$INPUT" | ruby -rjson -e 'begin; d=JSON.parse(STDIN.read); i=d["tool_input"]||d["toolInput"]||{}; print(i["subagent_type"].to_s); rescue StandardError; print ""; end' 2>/dev/null || true)"
  MODEL="$(printf '%s' "$INPUT" | ruby -rjson -e 'begin; d=JSON.parse(STDIN.read); i=d["tool_input"]||d["toolInput"]||{}; print(i["model"].to_s); rescue StandardError; print ""; end' 2>/dev/null || true)"
  CWD="$(printf '%s' "$INPUT" | ruby -rjson -e 'begin; print(JSON.parse(STDIN.read)["cwd"].to_s); rescue StandardError; print ""; end' 2>/dev/null || true)"
fi
[[ "$TOOL" == "Agent" ]] || allow
case "$TYPE" in lode:gate-*) ;; *) allow ;; esac

if [[ "${LODE_SKIP_GATE:-}" == "1" ]]; then
  echo "[lode:gate] LODE_SKIP_GATE=1 — allowing $TYPE without the ledger. Say why in the PR body." >&2
  allow
fi

START="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
ROOT="$(git -C "$START" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || allow

if [[ ! -d "$ROOT/lode" ]]; then
  echo "[lode:gate] no lode/ in this repo — allowing $TYPE. Run /lode:seed to enable the gate budget." >&2
  allow
fi

REASON="$(cd "$ROOT" && bash "$HERE/gate-ledger.sh" spawn "$TYPE" "$MODEL" 2>&1)" && allow
deny "$REASON"
