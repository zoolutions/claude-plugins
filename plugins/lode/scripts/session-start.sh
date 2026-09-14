#!/usr/bin/env bash
# SessionStart hook: put the lode's summary and map into context so the
# session starts with the repo's own memory, per Lode Coding. Stdout of a
# SessionStart hook is added to the conversation context.
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
if [[ ! -d "$ROOT/lode" ]]; then
  echo "lode: this repository has no lode/ yet. /lode:seed creates one and enables the pre-PR gate."
  exit 0
fi
echo "lode: this repository keeps its durable memory in lode/. Read lode/lode-map.md before exploring the codebase; it indexes every lode file. lode/review/ holds review findings turned into rules, which /lode:gate enforces before any push."
for f in summary.md lode-map.md; do
  if [[ -f "$ROOT/lode/$f" ]]; then
    echo; echo "--- lode/$f ---"
    head -c 6000 "$ROOT/lode/$f"
  fi
done
