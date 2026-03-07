#!/usr/bin/env bash
set -euo pipefail

default_cache_root() {
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "$HOME/Library/Caches/obsidian-yazi"
      ;;
    *)
      if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
        printf '%s\n' "${XDG_CACHE_HOME%/}/obsidian-yazi"
      else
        printf '%s\n' "$HOME/.cache/obsidian-yazi"
      fi
      ;;
  esac
}

expand_home_path() {
  local value="$1"
  if [[ "$value" == "~" ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  if [[ "$value" == "~/"* ]]; then
    printf '%s\n' "$HOME/${value#~/}"
    return 0
  fi
  printf '%s\n' "$value"
}

canonicalize_abs_path() {
  local value="$1"
  if [[ "$value" == "/" ]]; then
    printf '/\n'
    return 0
  fi
  if [[ "$value" != /* ]]; then
    return 1
  fi

  local current="$value"
  local suffix=""
  while [[ ! -d "$current" ]]; do
    local parent base
    parent="$(dirname "$current")"
    base="$(basename "$current")"
    if [[ -z "$base" || "$parent" == "$current" ]]; then
      return 1
    fi
    suffix="/$base$suffix"
    current="$parent"
  done

  local current_abs
  current_abs="$(cd "$current" 2>/dev/null && pwd -P)" || return 1
  printf '%s%s\n' "$current_abs" "$suffix"
}

CACHE_ROOT="${OBSIDIAN_YAZI_CACHE:-$(default_cache_root)}"
CACHE_ROOT="$(expand_home_path "$CACHE_ROOT")"
if ! CACHE_ROOT="$(canonicalize_abs_path "$CACHE_ROOT")"; then
  echo "Refusing cleanup for non-absolute cache root: '$CACHE_ROOT'" >&2
  exit 1
fi
TTL_DAYS="${OBSIDIAN_YAZI_TTL_DAYS:-3}"
LOCK_TTL_MIN="${OBSIDIAN_YAZI_LOCK_TTL_MIN:-15}"
SENTINEL_NAME=".obsidian-yazi-cache"

IMG_DIR="$CACHE_ROOT/img"
MODE_DIR="$CACHE_ROOT/mode"
LOCK_DIR="$CACHE_ROOT/locks"
LOG_DIR="$CACHE_ROOT/log"
REQUEST_DIR="$CACHE_ROOT/requests"
SENTINEL_PATH="$CACHE_ROOT/$SENTINEL_NAME"

if [[ -z "$CACHE_ROOT" || "$CACHE_ROOT" == "/" || "$CACHE_ROOT" == "$HOME" ]]; then
  echo "Refusing cleanup for unsafe cache root: '$CACHE_ROOT'" >&2
  exit 1
fi
if [[ ! -f "$SENTINEL_PATH" ]]; then
  echo "Refusing cleanup: sentinel not found at $SENTINEL_PATH" >&2
  exit 1
fi

mkdir -p "$IMG_DIR" "$MODE_DIR" "$LOCK_DIR" "$LOG_DIR" "$REQUEST_DIR"
chmod 700 "$CACHE_ROOT" "$IMG_DIR" "$MODE_DIR" "$LOCK_DIR" "$LOG_DIR" "$REQUEST_DIR" 2>/dev/null || true

if ! [[ "$TTL_DAYS" =~ ^[0-9]+$ ]]; then
  TTL_DAYS=3
fi
if ! [[ "$LOCK_TTL_MIN" =~ ^[0-9]+$ ]]; then
  LOCK_TTL_MIN=15
fi

if (( TTL_DAYS > 365 )); then
  echo "TTL_DAYS too large ($TTL_DAYS). Clamping to 365." >&2
  TTL_DAYS=365
fi

total_cleaned=0
count_delete() {
  local count
  count="$(find "$@" -print -delete | wc -l | tr -d '[:space:]')"
  total_cleaned=$((total_cleaned + count))
}

count_delete "$IMG_DIR" -type f -name '*.png' -mtime "+$TTL_DAYS"
count_delete "$IMG_DIR" -type f -name '*.meta.json' -mtime "+$TTL_DAYS"
count_delete "$LOCK_DIR" -type f -name '*.lock' -mmin "+$LOCK_TTL_MIN"
count_delete "$LOCK_DIR" -type f -name '.curl-auth-*.header' -mmin "+$LOCK_TTL_MIN"
count_delete "$LOG_DIR" -type f -mtime "+$TTL_DAYS"
count_delete "$REQUEST_DIR" -type f -mtime "+$TTL_DAYS"

echo "$total_cleaned files cleaned up"

# Keep mode flags to preserve per-note toggle preference.
exit 0
