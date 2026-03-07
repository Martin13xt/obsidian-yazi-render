#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_VAULT_ROOT="$HOME/obsidian"
VAULT_ROOT="${OBSIDIAN_VAULT_ROOT:-$DEFAULT_VAULT_ROOT}"
DEFAULT_YAZI_CONFIG_DIR="${YAZI_CONFIG_HOME:-$HOME/.config/yazi}"
YAZI_CONFIG_DIR="${YAZI_CONFIG_DIR:-$DEFAULT_YAZI_CONFIG_DIR}"
REQUIRE_BUILD=0
HAS_FAIL=0
NODE_MIN_MAJOR=20
NODE_MIN_MINOR=19
NODE_MIN_PATCH=0
NODE_MIN_VERSION="${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}.${NODE_MIN_PATCH}"
VAULT_SOURCE="fallback"
if [[ -n "${OBSIDIAN_VAULT_ROOT:-}" ]]; then
  VAULT_SOURCE="env"
fi

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --vault <path>            Obsidian Vault root path (recommended; fallback: $HOME/obsidian)
  --yazi-config <path>      Yazi config root path (default: \$YAZI_CONFIG_DIR > \$YAZI_CONFIG_HOME > $HOME/.config/yazi)
  --require-build           Require node/npm checks even if prebuilt exists
  -h, --help                Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --vault" >&2
        usage
        exit 1
      fi
      VAULT_ROOT="$2"
      VAULT_SOURCE="flag"
      shift 2
      ;;
    --yazi-config)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --yazi-config" >&2
        usage
        exit 1
      fi
      YAZI_CONFIG_DIR="$2"
      shift 2
      ;;
    --require-build)
      REQUIRE_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

ok() {
  printf "[OK] %s\n" "$1"
}

warn() {
  printf "[WARN] %s\n" "$1"
}

fail() {
  HAS_FAIL=1
  printf "[FAIL] %s\n" "$1"
}

info() {
  printf "[INFO] %s\n" "$1"
}

check_cmd() {
  local cmd="$1"
  local required="${2:-1}"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "command '$cmd' is available"
  else
    if [[ "$required" == "1" ]]; then
      fail "command '$cmd' is missing"
    else
      warn "command '$cmd' is missing (optional)"
    fi
  fi
}

check_obsidian_cli() {
  if command -v obsidian >/dev/null 2>&1; then
    ok "Obsidian CLI found: obsidian"
    return 0
  fi
  if command -v Obsidian.com >/dev/null 2>&1; then
    ok "Obsidian CLI found: Obsidian.com"
    return 0
  fi
  warn "Obsidian CLI not found (optional; needed only for CLI fallback)"
  return 0
}

check_node_min_version() {
  local required="${1:-1}"
  if ! command -v node >/dev/null 2>&1; then
    if [[ "$required" == "1" ]]; then
      fail "command 'node' is missing"
    else
      warn "command 'node' is missing (optional)"
    fi
    return
  fi

  local version_raw
  version_raw="$(node -p 'process.versions.node' 2>/dev/null || true)"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$version_raw"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "${minor:-}" =~ ^[0-9]+$ ]]; then
    if [[ "$required" == "1" ]]; then
      fail "failed to parse Node.js version: ${version_raw:-unknown}"
    else
      warn "failed to parse Node.js version: ${version_raw:-unknown}"
    fi
    return
  fi

  patch="${patch:-0}"
  patch="${patch%%[^0-9]*}"
  if [[ -z "$patch" ]]; then
    patch=0
  fi

  local too_old=0
  if (( major < NODE_MIN_MAJOR )); then
    too_old=1
  elif (( major == NODE_MIN_MAJOR )) && (( minor < NODE_MIN_MINOR )); then
    too_old=1
  elif (( major == NODE_MIN_MAJOR )) && (( minor == NODE_MIN_MINOR )) && (( patch < NODE_MIN_PATCH )); then
    too_old=1
  fi

  if (( too_old == 1 )); then
    local msg="Node.js >=${NODE_MIN_VERSION} is required for source builds (found: $version_raw)"
    if [[ "$required" == "1" ]]; then
      fail "$msg"
    else
      warn "$msg"
    fi
    return
  fi

  ok "node version is supported ($version_raw)"
}

check_digest_tool() {
  local probe="obsidian-yazi-doctor"
  local digest=""

  if command -v md5 >/dev/null 2>&1; then
    digest="$(md5 -q -s "$probe" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$digest" =~ ^[A-Fa-f0-9]{32}$ ]]; then
      ok "digest command works (md5)"
      return
    fi
    warn "md5 exists but did not return a valid 32-hex digest"
  fi

  if command -v md5sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$probe" | md5sum 2>/dev/null | awk '{print $1}' | tr -d '[:space:]' || true)"
    if [[ "$digest" =~ ^[A-Fa-f0-9]{32}$ ]]; then
      ok "digest command works (md5sum)"
      return
    fi
    warn "md5sum exists but did not return a valid 32-hex digest"
  fi

  fail "digest command unavailable or invalid (need working md5 or md5sum)"
}

sha256_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}' | tr -d '[:space:]'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}' | tr -d '[:space:]'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}' | tr -d '[:space:]'
    return 0
  fi
  return 1
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|on|ON)
      return 0
      ;;
  esac
  return 1
}

is_loopback_host() {
  case "${1:-}" in
    127.0.0.1|localhost|::1)
      return 0
      ;;
  esac
  return 1
}

rest_probe() {
  local settings="$1"
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq is missing; skipping REST connectivity check"
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl is missing; skipping REST connectivity check"
    return
  fi

  local host="${OBSIDIAN_REST_HOST:-127.0.0.1}"
  local allow_remote="${OBSIDIAN_REST_ALLOW_REMOTE:-0}"
  if ! is_loopback_host "$host" && ! is_truthy "$allow_remote"; then
    warn "REST host is non-loopback (${host}). Set OBSIDIAN_REST_ALLOW_REMOTE=1 to allow remote checks."
    return
  fi

  local secure_port insecure_port enable_insecure
  secure_port="$(jq -r '.port // 27124' "$settings" 2>/dev/null)"
  insecure_port="$(jq -r '.insecurePort // 27123' "$settings" 2>/dev/null)"
  enable_insecure="$(jq -r '.enableInsecureServer // false' "$settings" 2>/dev/null)"

  local insecure_env="${OBSIDIAN_REST_INSECURE:-}"
  local port_env="${OBSIDIAN_REST_PORT:-}"
  local verify_tls_env="${OBSIDIAN_REST_VERIFY_TLS:-}"

  local insecure_final
  if [[ -n "$insecure_env" ]]; then
    insecure_final="$insecure_env"
  else
    if is_loopback_host "$host"; then
      insecure_final="$enable_insecure"
    else
      insecure_final="false"
    fi
  fi

  local scheme="https"
  if is_truthy "$insecure_final"; then
    scheme="http"
  fi

  local port_final="$port_env"
  if [[ -z "$port_final" ]]; then
    if [[ "$scheme" == "http" ]]; then
      port_final="$insecure_port"
    else
      port_final="$secure_port"
    fi
  fi

  if [[ -z "$port_final" ]]; then
    warn "REST port not found; skipping REST connectivity check"
    return
  fi

  local curl_args=(-sS --connect-timeout 2 --max-time 3 -o /dev/null -w "%{http_code}")
  if [[ "$scheme" == "https" ]]; then
    if [[ -z "$verify_tls_env" ]]; then
      if is_loopback_host "$host"; then
        curl_args=(-k "${curl_args[@]}")
      fi
    elif [[ "$verify_tls_env" == "0" ]]; then
      if is_loopback_host "$host"; then
        curl_args=(-k "${curl_args[@]}")
      else
        warn "REST TLS verification is disabled for a non-loopback host; skipping connectivity check"
        return
      fi
    fi
  fi

  local code
  code="$(curl "${curl_args[@]}" "$scheme://$host:$port_final/")" || true
  if [[ -z "$code" || "$code" == "000" ]]; then
    warn "REST API not reachable at $scheme://$host:$port_final (is Obsidian running?)"
    return
  fi

  ok "REST API reachable (HTTP $code)"
}

PREBUILT_MAIN="$PACK_ROOT/obsidian-plugin/yazi-exporter/prebuilt/main.js"
PREBUILT_SUM="$PACK_ROOT/obsidian-plugin/yazi-exporter/prebuilt/main.js.sha256"
NEED_NODE=1

prebuilt_ok=0
prebuilt_issue=""
if [[ -f "$PREBUILT_MAIN" ]]; then
  if [[ -f "$PREBUILT_SUM" ]]; then
    if actual_sum="$(sha256_file "$PREBUILT_MAIN")"; then
      expected_sum="$(awk '{print $1}' "$PREBUILT_SUM" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
      actual_sum="$(printf '%s' "$actual_sum" | tr '[:upper:]' '[:lower:]')"
      if [[ -n "$expected_sum" && "$expected_sum" == "$actual_sum" ]]; then
        prebuilt_ok=1
      else
        prebuilt_ok=0
        prebuilt_issue="prebuilt checksum mismatch"
      fi
    else
      prebuilt_ok=0
      prebuilt_issue="no SHA-256 command found (need shasum, sha256sum, or openssl) for prebuilt checksum verification"
    fi
  else
    prebuilt_ok=0
    prebuilt_issue="prebuilt checksum file is missing"
  fi
fi

if [[ "$prebuilt_ok" -eq 1 && "$REQUIRE_BUILD" -eq 0 ]]; then
  NEED_NODE=0
fi

echo "== Obsidian Yazi Render Doctor =="
echo "Vault: $VAULT_ROOT"
echo "Yazi config: $YAZI_CONFIG_DIR"
if [[ "$VAULT_SOURCE" == "fallback" ]]; then
  info "No --vault provided. Using fallback path '$DEFAULT_VAULT_ROOT' (recommended: pass --vault <your-vault>)."
fi
echo

if [[ "$(uname -s)" == "Darwin" ]]; then
  ok "macOS detected"
else
  warn "non-macOS environment detected"
  info "Recommended cache path examples:"
  info '  non-macOS: export OBSIDIAN_YAZI_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/obsidian-yazi"'
fi

echo
echo "-- Runtime dependencies --"
check_cmd yazi 1
check_cmd jq 1
check_cmd curl 1
check_digest_tool

echo
echo "-- Build dependencies --"
if [[ "$NEED_NODE" -eq 1 ]]; then
  check_node_min_version 1
  check_cmd npm 1
  if [[ -n "$prebuilt_issue" ]]; then
    warn "$prebuilt_issue: $PREBUILT_MAIN"
  fi
else
  ok "prebuilt plugin found: $PREBUILT_MAIN"
  if [[ -f "$PREBUILT_SUM" ]]; then
    info "prebuilt checksum matched (integrity only): $PREBUILT_SUM"
    warn "co-located checksum is not sufficient for tamper detection. Use install.sh --prebuilt-sha256 with an externally verified hash."
  fi
  check_node_min_version 0
  check_cmd npm 0
fi

echo
echo "-- Optional dependencies --"
check_cmd launchctl 0
check_cmd brew 0
check_cmd tmux 0
check_obsidian_cli
if [[ "${OBSIDIAN_YAZI_CLI_FALLBACK:-0}" != "0" || "${OBSIDIAN_YAZI_AUTO_CLI_FALLBACK:-0}" != "0" || "${OBSIDIAN_YAZI_URI_FALLBACK:-0}" != "0" || "${OBSIDIAN_YAZI_AUTO_URI_FALLBACK:-0}" != "0" ]]; then
  info "fallback env detected (CLI/URI fallback enabled)"
  if [[ -z "${OBSIDIAN_VAULT_NAME:-}" ]]; then
    warn "fallback is enabled but OBSIDIAN_VAULT_NAME is unset. Default vault name 'obsidian' may not match your actual vault."
  else
    info "CLI/URI target vault name: OBSIDIAN_VAULT_NAME=${OBSIDIAN_VAULT_NAME}"
  fi
fi
if [[ "${OBSIDIAN_YAZI_USE_REST:-1}" == "0" && "${OBSIDIAN_YAZI_CLI_FALLBACK:-0}" == "0" && "${OBSIDIAN_YAZI_URI_FALLBACK:-0}" == "0" && "${OBSIDIAN_YAZI_AUTO_URI_FALLBACK:-0}" == "0" ]]; then
  warn "OBSIDIAN_YAZI_USE_REST=0 but no CLI/URI fallback is enabled. Regeneration requests will fail."
fi

echo
echo "-- Terminal/tmux path --"
info "TERM=${TERM:-unknown}"
if [[ -n "${TMUX:-}" ]]; then
  ok "running inside tmux"
else
  info "not currently inside tmux"
fi

if command -v tmux >/dev/null 2>&1; then
  if [[ -n "${TMUX:-}" ]]; then
    allow_passthrough="$(tmux show -gv allow-passthrough 2>/dev/null || true)"
    if [[ "$allow_passthrough" == "on" || "$allow_passthrough" == "all" ]]; then
      ok "tmux allow-passthrough = $allow_passthrough"
    else
      warn "tmux allow-passthrough = '${allow_passthrough:-unset}'. Recommended: set -g allow-passthrough on"
    fi

    default_terminal="$(tmux show -gqv default-terminal 2>/dev/null || true)"
    if [[ -z "$default_terminal" || "$default_terminal" == tmux* || "$default_terminal" == screen* ]]; then
      ok "tmux default-terminal = ${default_terminal:-auto}"
    else
      warn "tmux default-terminal is '$default_terminal'. Recommended: tmux-256color or screen/tmux derivative."
    fi
  else
    tmux_conf="${TMUX_CONF:-$HOME/.tmux.conf}"
    if [[ -f "$tmux_conf" ]]; then
      if grep -Eq '^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+allow-passthrough[[:space:]]+(on|all)\b' "$tmux_conf"; then
        ok "tmux config enables allow-passthrough"
      else
        warn "tmux config does not enable allow-passthrough. Add: set -g allow-passthrough on"
      fi
    else
      warn "tmux config not found at $tmux_conf (cannot pre-check passthrough setting)"
    fi
  fi
fi

if [[ -n "${TMUX:-}" && "${TERM:-}" != tmux* && "${TERM:-}" != screen* ]]; then
  warn "inside tmux but TERM='${TERM:-}'. This may break image preview behavior."
fi

echo
echo "-- Yazi integration --"
YAZI_TOML="$YAZI_CONFIG_DIR/yazi.toml"
KEYMAP_TOML="$YAZI_CONFIG_DIR/keymap.toml"

if [[ -f "$YAZI_TOML" ]]; then
  ok "yazi.toml exists"
  if grep -q 'run = "obsidian-preview"' "$YAZI_TOML"; then
    ok "markdown preloader is configured for obsidian-preview"
  else
    warn "obsidian-preview preloader is not found in yazi.toml"
  fi
else
  warn "missing yazi.toml: $YAZI_TOML"
fi

if [[ -f "$KEYMAP_TOML" ]]; then
  ok "keymap.toml exists"
  if grep -q '^# obsidian-yazi-render:custom-keys:start$' "$KEYMAP_TOML" && grep -q '^# obsidian-yazi-render:custom-keys:end$' "$KEYMAP_TOML"; then
    ok "managed obsidian key block exists"
  else
    warn "managed obsidian key block not found; run install.sh to reapply keys"
  fi

  obsidian_key_lines="$(grep -Ec 'plugin[[:space:]]+obsidian-(toggle|refresh|nav|tune)' "$KEYMAP_TOML" || true)"
  if [[ "${obsidian_key_lines:-0}" -gt 14 ]]; then
    warn "multiple obsidian key bindings detected (${obsidian_key_lines}). Legacy duplicates may shadow keys."
  else
    ok "obsidian key binding count looks healthy (${obsidian_key_lines})"
  fi
else
  warn "missing keymap.toml: $KEYMAP_TOML"
fi

echo
echo "-- Vault checks --"
if [[ -d "$VAULT_ROOT/.obsidian" ]]; then
  ok "Vault exists: $VAULT_ROOT/.obsidian"
else
  fail "Vault not found: $VAULT_ROOT/.obsidian"
fi

REST_CONFIG="$VAULT_ROOT/.obsidian/plugins/obsidian-local-rest-api/data.json"
if [[ -f "$REST_CONFIG" ]]; then
  ok "Local REST API config exists"
  if command -v jq >/dev/null 2>&1; then
    API_KEY_LEN="$(jq -r '.apiKey // ""' "$REST_CONFIG" | wc -c | tr -d ' ')"
    if [[ "${API_KEY_LEN:-0}" -gt 1 ]]; then
      ok "Local REST API apiKey is configured"
    else
      warn "Local REST API apiKey is empty"
    fi
  else
    warn "jq is missing; cannot inspect Local REST API apiKey value"
  fi
  rest_probe "$REST_CONFIG"
else
  warn "Local REST API config not found: $REST_CONFIG"
fi

echo
echo "Doctor completed."

if [[ "$HAS_FAIL" -ne 0 ]]; then
  exit 1
fi
