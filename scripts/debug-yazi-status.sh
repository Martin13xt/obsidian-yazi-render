#!/usr/bin/env bash
set -euo pipefail

CACHE="${OBSIDIAN_YAZI_CACHE:-$HOME/Library/Caches/obsidian-yazi}"
JQ="${JQ_BIN:-/opt/homebrew/bin/jq}"
CURL="${CURL_BIN:-/usr/bin/curl}"
SLEEP_BIN="${SLEEP_BIN:-/bin/sleep}"
DATE_BIN="${DATE_BIN:-/bin/date}"
SEQ_BIN="${SEQ_BIN:-/usr/bin/seq}"

TRIGGER=1
LOOPS=12

if [[ "${DEBUG_YAZI_NO_TRIGGER:-0}" == "1" ]]; then
  TRIGGER=0
fi
if [[ -n "${DEBUG_YAZI_LOOPS:-}" ]]; then
  LOOPS="${DEBUG_YAZI_LOOPS}"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--trigger)
      TRIGGER=1
      shift
      ;;
    -n|--no-trigger)
      TRIGGER=0
      shift
      ;;
    --no-)
      if [[ "${2:-}" == "trigger" ]]; then
        TRIGGER=0
        shift 2
      else
        echo "unknown arg: $1 ${2:-}" >&2
        echo "usage: bash scripts/debug-yazi-status.sh [--trigger|--no-trigger|-t|-n] [--loops N|-l N]" >&2
        exit 2
      fi
      ;;
    -l|--loops)
      LOOPS="${2:-12}"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      echo "usage: bash scripts/debug-yazi-status.sh [--trigger|--no-trigger|-t|-n] [--loops N|-l N]" >&2
      exit 2
      ;;
  esac
done

if [[ ! -x "$JQ" ]]; then
  echo "jq not found at: $JQ" >&2
  exit 1
fi

calc_md5() {
  local value="$1"
  if command -v md5 >/dev/null 2>&1; then
    md5 -q -s "$value" 2>/dev/null || true
    return
  fi
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$value" | md5sum | awk '{print $1}'
    return
  fi
  printf ''
}

REQ="$CACHE/requests/current.json"
if [[ ! -f "$REQ" ]]; then
  echo "current.json missing: $REQ"
  exit 1
fi

echo "== request =="
"$JQ" '{path,digest,requestId,requestedAt}' "$REQ"

DIGEST="$("$JQ" -r '.digest // empty' "$REQ")"
if [[ -z "$DIGEST" ]]; then
  echo "digest is empty in request json" >&2
  exit 1
fi
REQ_PATH="$("$JQ" -r '.path // empty' "$REQ")"
CALC_DIGEST="$(calc_md5 "$REQ_PATH")"
echo "digest(request)=$DIGEST"
if [[ -n "$CALC_DIGEST" ]]; then
  if [[ "$CALC_DIGEST" == "$DIGEST" ]]; then
    echo "digest(calc)   =$CALC_DIGEST (match)"
  else
    echo "digest(calc)   =$CALC_DIGEST (mismatch)"
  fi
else
  echo "digest(calc)   =(unavailable: md5/md5sum not found)"
fi

if [[ "$TRIGGER" == "1" ]]; then
  REST_SETTINGS="$HOME/obsidian/.obsidian/plugins/obsidian-local-rest-api/data.json"
  if [[ ! -f "$REST_SETTINGS" ]]; then
    echo "rest settings missing: $REST_SETTINGS" >&2
    exit 1
  fi
  API_KEY="$("$JQ" -r '.apiKey // empty' "$REST_SETTINGS")"
  PORT="$("$JQ" -r '.port // 27124' "$REST_SETTINGS")"
  if [[ -z "$API_KEY" ]]; then
    echo "apiKey missing in $REST_SETTINGS" >&2
    exit 1
  fi
  CODE="$("$CURL" -k -sS -o /tmp/oy-post.out -w '%{http_code}' \
    "https://127.0.0.1:${PORT}/commands/yazi-exporter%3Aexport-requested-to-cache" \
    -H "Authorization: Bearer ${API_KEY}" -X POST || true)"
  echo "POST=$CODE"
fi

STATUS="$CACHE/log/${DIGEST}.status.json"
STATUS_CALC="$CACHE/log/${CALC_DIGEST}.status.json"
for i in $("$SEQ_BIN" 1 "$LOOPS"); do
  TS="$("$DATE_BIN" +%H:%M:%S)"
  if [[ -f "$STATUS" ]]; then
    echo -n "${TS} [request] "
    "$JQ" -c '{state,stage,requestId,updatedAt,error}' "$STATUS" || echo parse-error
  elif [[ -n "$CALC_DIGEST" && -f "$STATUS_CALC" ]]; then
    echo -n "${TS} [calc] "
    "$JQ" -c '{state,stage,requestId,updatedAt,error}' "$STATUS_CALC" || echo parse-error
  else
    echo "${TS} status-missing"
  fi
  "$SLEEP_BIN" 1
done

if [[ -f "$CACHE/log/${DIGEST}.error.json" ]]; then
  echo "== error(request) =="
  "$JQ" '.' "$CACHE/log/${DIGEST}.error.json" || cat "$CACHE/log/${DIGEST}.error.json"
fi
if [[ -n "$CALC_DIGEST" && "$CALC_DIGEST" != "$DIGEST" && -f "$CACHE/log/${CALC_DIGEST}.error.json" ]]; then
  echo "== error(calc) =="
  "$JQ" '.' "$CACHE/log/${CALC_DIGEST}.error.json" || cat "$CACHE/log/${CALC_DIGEST}.error.json"
fi
