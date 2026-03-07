#!/usr/bin/env bash
set -euo pipefail

CACHE="${OBSIDIAN_YAZI_CACHE:-$HOME/Library/Caches/obsidian-yazi}"
JQ="${JQ_BIN:-/opt/homebrew/bin/jq}"
REQ="$CACHE/requests/current.json"

if [[ ! -x "$JQ" ]]; then
  echo "jq not found at: $JQ" >&2
  exit 1
fi

if [[ ! -f "$REQ" ]]; then
  echo "current.json missing: $REQ" >&2
  exit 1
fi

d="$("$JQ" -r '.digest // empty' "$REQ")"
if [[ -z "$d" ]]; then
  echo "digest is empty in $REQ" >&2
  exit 1
fi

echo "digest=$d"

transport="$CACHE/log/$d.transport.error.txt"
ui="$CACHE/log/$d.ui.error.txt"

if [[ -f "$transport" ]]; then
  echo "== transport =="
  cat "$transport"
else
  echo "transport: none"
fi

if [[ -f "$ui" ]]; then
  echo "== ui =="
  cat "$ui"
else
  echo "ui: none"
fi
