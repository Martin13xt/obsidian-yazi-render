#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LABEL="${OBSIDIAN_YAZI_LAUNCHD_LABEL:-com.obsidian-yazi-cache-cleanup}"
HOUR="${OBSIDIAN_YAZI_CLEANUP_HOUR:-4}"
MINUTE="${OBSIDIAN_YAZI_CLEANUP_MINUTE:-10}"
PLIST_DEST="${OBSIDIAN_YAZI_PLIST_DEST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
LOG_OUT="${OBSIDIAN_YAZI_CLEANUP_LOG:-$HOME/Library/Logs/obsidian-yazi-cache-cleanup.log}"
LOG_ERR="${OBSIDIAN_YAZI_CLEANUP_ERR_LOG:-$HOME/Library/Logs/obsidian-yazi-cache-cleanup.err.log}"
CACHE_ROOT="${OBSIDIAN_YAZI_CACHE:-}"
CLEANUP_SCRIPT="$SCRIPT_DIR/cleanup-cache.sh"
BACKUP_DIR="${OBSIDIAN_YAZI_BACKUP_DIR:-}"
ALLOW_CUSTOM_PLIST_DEST="${OBSIDIAN_YAZI_ALLOW_CUSTOM_PLIST_DEST:-0}"
LAUNCHD_DOMAIN="gui/$(id -u)"

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

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

if ! [[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid launchd label: $LABEL" >&2
  exit 1
fi
if ! [[ "$HOUR" =~ ^[0-9]{1,2}$ ]] || (( HOUR < 0 || HOUR > 23 )); then
  echo "Invalid cleanup hour: $HOUR (expected 0-23)" >&2
  exit 1
fi
if ! [[ "$MINUTE" =~ ^[0-9]{1,2}$ ]] || (( MINUTE < 0 || MINUTE > 59 )); then
  echo "Invalid cleanup minute: $MINUTE (expected 0-59)" >&2
  exit 1
fi

if [[ ! -x "$CLEANUP_SCRIPT" ]]; then
  chmod +x "$CLEANUP_SCRIPT"
fi

if ! command -v launchctl >/dev/null 2>&1; then
  echo "launchctl not found. install-launchd.sh is macOS-only." >&2
  exit 1
fi

PLIST_DEST="$(expand_home_path "$PLIST_DEST")"
PLIST_DEST="$(canonicalize_abs_path "$PLIST_DEST" || true)"
if [[ -z "$PLIST_DEST" ]]; then
  echo "Invalid plist destination path." >&2
  exit 1
fi

LAUNCH_AGENTS_ROOT="$(canonicalize_abs_path "$HOME/Library/LaunchAgents" || true)"
if [[ -z "$LAUNCH_AGENTS_ROOT" ]]; then
  echo "Failed to resolve LaunchAgents directory." >&2
  exit 1
fi

if [[ "$PLIST_DEST" != "$LAUNCH_AGENTS_ROOT/"* ]] && [[ "$ALLOW_CUSTOM_PLIST_DEST" != "1" ]]; then
  echo "Refusing custom plist destination: $PLIST_DEST" >&2
  echo "Set OBSIDIAN_YAZI_ALLOW_CUSTOM_PLIST_DEST=1 to allow non-default paths." >&2
  exit 1
fi

if [[ -n "$CACHE_ROOT" ]]; then
  CACHE_ROOT="$(expand_home_path "$CACHE_ROOT")"
  CACHE_ROOT="$(canonicalize_abs_path "$CACHE_ROOT" || true)"
  if [[ -z "$CACHE_ROOT" ]]; then
    echo "Invalid cache root path for launchd environment." >&2
    exit 1
  fi
  if [[ "$CACHE_ROOT" == "/" || "$CACHE_ROOT" == "$HOME" ]]; then
    echo "Refusing unsafe cache root for launchd environment: $CACHE_ROOT" >&2
    exit 1
  fi
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$(dirname "$LOG_OUT")"
mkdir -p "$(dirname "$LOG_ERR")"

LABEL_XML="$(xml_escape "$LABEL")"
CLEANUP_SCRIPT_XML="$(xml_escape "$CLEANUP_SCRIPT")"
LOG_OUT_XML="$(xml_escape "$LOG_OUT")"
LOG_ERR_XML="$(xml_escape "$LOG_ERR")"
CACHE_ROOT_XML="$(xml_escape "$CACHE_ROOT")"
PLIST_DEST_DIR="$(dirname "$PLIST_DEST")"
mkdir -p "$PLIST_DEST_DIR"

ENVIRONMENT_BLOCK=""
if [[ -n "$CACHE_ROOT" ]]; then
  ENVIRONMENT_BLOCK="  <key>EnvironmentVariables</key>
  <dict>
    <key>OBSIDIAN_YAZI_CACHE</key>
    <string>$CACHE_ROOT_XML</string>
  </dict>
"
fi

PLIST_BACKUP=""
if [[ -f "$PLIST_DEST" ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -n "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR"
    PLIST_BACKUP="$BACKUP_DIR/$(basename "$PLIST_DEST").$stamp.bak"
  else
    PLIST_BACKUP="$PLIST_DEST.bak.$stamp"
  fi
  cp -p "$PLIST_DEST" "$PLIST_BACKUP"
fi

TMP_PLIST="$(mktemp "$PLIST_DEST_DIR/.${LABEL}.tmp.XXXXXX")"
cleanup_tmp_plist() {
  rm -f "$TMP_PLIST"
}
trap cleanup_tmp_plist EXIT

cat > "$TMP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL_XML</string>

  <key>ProgramArguments</key>
  <array>
    <string>$CLEANUP_SCRIPT_XML</string>
  </array>

$ENVIRONMENT_BLOCK

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$HOUR</integer>
    <key>Minute</key>
    <integer>$MINUTE</integer>
  </dict>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>$LOG_OUT_XML</string>
  <key>StandardErrorPath</key>
  <string>$LOG_ERR_XML</string>
</dict>
</plist>
EOF

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$TMP_PLIST" >/dev/null
fi

restore_previous_plist() {
  if [[ -n "$PLIST_BACKUP" && -f "$PLIST_BACKUP" ]]; then
    cp -p "$PLIST_BACKUP" "$PLIST_DEST"
  else
    rm -f "$PLIST_DEST"
  fi
}

rollback_install() {
  local reason="$1"
  echo "launchd install failed: $reason" >&2
  launchctl bootout "$LAUNCHD_DOMAIN/$LABEL" >/dev/null 2>&1 || true
  restore_previous_plist
  if [[ -n "$PLIST_BACKUP" && -f "$PLIST_BACKUP" ]]; then
    if launchctl bootstrap "$LAUNCHD_DOMAIN" "$PLIST_DEST" >/dev/null 2>&1; then
      launchctl enable "$LAUNCHD_DOMAIN/$LABEL" >/dev/null 2>&1 || true
      echo "Restored previous launchd agent from backup." >&2
    else
      echo "Warning: failed to bootstrap previous launchd agent after rollback." >&2
    fi
  fi
  exit 1
}

mv "$TMP_PLIST" "$PLIST_DEST"
trap - EXIT

launchctl bootout "$LAUNCHD_DOMAIN/$LABEL" >/dev/null 2>&1 || true
if ! launchctl bootstrap "$LAUNCHD_DOMAIN" "$PLIST_DEST"; then
  rollback_install "launchctl bootstrap failed"
fi
if ! launchctl enable "$LAUNCHD_DOMAIN/$LABEL"; then
  rollback_install "launchctl enable failed"
fi

echo "Installed: $PLIST_DEST"
if [[ -n "$PLIST_BACKUP" ]]; then
  echo "Plist backup: $PLIST_BACKUP"
fi
echo "Package root: $PACK_ROOT"
launchctl print "$LAUNCHD_DOMAIN/$LABEL" | sed -n '1,24p'
