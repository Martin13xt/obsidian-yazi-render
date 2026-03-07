#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VAULT_ROOT="${OBSIDIAN_VAULT_ROOT:-}"
DEFAULT_YAZI_CONFIG_DIR="${YAZI_CONFIG_HOME:-$HOME/.config/yazi}"
YAZI_CONFIG_DIR="${YAZI_CONFIG_DIR:-$DEFAULT_YAZI_CONFIG_DIR}"
CACHE_ROOT="${OBSIDIAN_YAZI_CACHE:-$HOME/Library/Caches/obsidian-yazi}"
PREBUILT_EXPECTED_SHA256="${OBSIDIAN_PREBUILT_SHA256:-}"
INSTALL_LAUNCHD=1
AUTO_BREW=0
YES=0
SKIP_NPM_INSTALL=0
FORCE_BUILD=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --vault <path>            Obsidian Vault root path
  --yazi-config <path>      Yazi config dir (default: \$YAZI_CONFIG_DIR > \$YAZI_CONFIG_HOME > $HOME/.config/yazi)
  --cache <path>            Cache dir (default: $HOME/Library/Caches/obsidian-yazi)
  --prebuilt-sha256 <hex>   Trusted SHA-256 for prebuilt main.js (optional)
  --auto-brew               Install missing dependencies with Homebrew
  --no-launchd              Do not install launchd cleanup job
  --skip-npm-install        Skip npm install, run build only
  --force-build             Ignore prebuilt plugin and build with npm
  --yes                     Non-interactive mode
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
    --cache)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --cache" >&2
        usage
        exit 1
      fi
      CACHE_ROOT="$2"
      shift 2
      ;;
    --prebuilt-sha256)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --prebuilt-sha256" >&2
        usage
        exit 1
      fi
      PREBUILT_EXPECTED_SHA256="$2"
      shift 2
      ;;
    --auto-brew)
      AUTO_BREW=1
      shift
      ;;
    --no-launchd)
      INSTALL_LAUNCHD=0
      shift
      ;;
    --skip-npm-install)
      SKIP_NPM_INSTALL=1
      shift
      ;;
    --force-build)
      FORCE_BUILD=1
      shift
      ;;
    --yes)
      YES=1
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This easy installer currently targets macOS." >&2
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sha256_file() {
  local file="$1"
  if need_cmd shasum; then
    shasum -a 256 "$file" | awk '{print $1}' | tr -d '[:space:]'
    return 0
  fi
  if need_cmd sha256sum; then
    sha256sum "$file" | awk '{print $1}' | tr -d '[:space:]'
    return 0
  fi
  if need_cmd openssl; then
    openssl dgst -sha256 "$file" | awk '{print $NF}' | tr -d '[:space:]'
    return 0
  fi
  return 1
}

prebuilt_is_usable() {
  local main_js="$PACK_ROOT/obsidian-plugin/yazi-exporter/prebuilt/main.js"
  if [[ ! -f "$main_js" ]]; then
    return 1
  fi
  if [[ -z "$PREBUILT_EXPECTED_SHA256" ]]; then
    return 1
  fi
  if [[ ! "$PREBUILT_EXPECTED_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    return 1
  fi

  local actual
  if ! actual="$(sha256_file "$main_js")"; then
    return 1
  fi
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
  local expected
  expected="$(printf '%s' "$PREBUILT_EXPECTED_SHA256" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$expected" && "$expected" == "$actual" ]]
}

needs_node_toolchain() {
  if [[ "$FORCE_BUILD" -eq 1 ]]; then
    return 0
  fi
  if prebuilt_is_usable; then
    return 1
  fi
  return 0
}

install_missing_with_brew() {
  if ! need_cmd brew; then
    echo "Homebrew is required for --auto-brew but not found." >&2
    echo "Install Homebrew first: https://brew.sh" >&2
    exit 1
  fi

  local formulas=()
  need_cmd yazi || formulas+=("yazi")
  need_cmd jq || formulas+=("jq")
  need_cmd curl || formulas+=("curl")
  if needs_node_toolchain; then
    need_cmd npm || formulas+=("node")
  fi

  if [[ "${#formulas[@]}" -gt 0 ]]; then
    echo "Installing missing dependencies via Homebrew: ${formulas[*]}"
    brew install "${formulas[@]}"
  fi
}

require_or_suggest() {
  local missing=()
  need_cmd yazi || missing+=("yazi")
  need_cmd jq || missing+=("jq")
  need_cmd curl || missing+=("curl")
  if needs_node_toolchain; then
    need_cmd npm || missing+=("npm (install via 'brew install node')")
  fi

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return
  fi

  echo "Missing required commands:"
  for item in "${missing[@]}"; do
    echo "  - $item"
  done
  echo
  echo "Option:"
  echo "  ./scripts/install-easy.sh --auto-brew"
  exit 1
}

pick_vault() {
  if [[ -n "$VAULT_ROOT" ]]; then
    return
  fi

  if [[ -d "$HOME/obsidian/.obsidian" ]]; then
    VAULT_ROOT="$HOME/obsidian"
    return
  fi

  candidates=()
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && candidates+=("$candidate")
  done < <(
    find "$HOME" -maxdepth 4 -type d -name ".obsidian" 2>/dev/null \
      | sed 's|/.obsidian$||' \
      | sort -u
  )

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "No Obsidian Vault was auto-detected." >&2
    echo "Specify vault path with --vault <path>." >&2
    exit 1
  fi

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    VAULT_ROOT="${candidates[0]}"
    return
  fi

  if [[ "$YES" -eq 1 ]]; then
    echo "Multiple Obsidian Vaults were detected." >&2
    echo "In --yes mode, please specify the target vault explicitly:" >&2
    echo "  ./scripts/install-easy.sh --vault <path> --yes" >&2
    exit 1
  fi

  echo "Select your Vault:"
  local i=1
  for c in "${candidates[@]}"; do
    echo "  $i) $c"
    i=$((i + 1))
  done

  local selection=""
  read -r -p "Enter number [1-${#candidates[@]}]: " selection
  if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#candidates[@]} )); then
    echo "Invalid selection." >&2
    exit 1
  fi
  VAULT_ROOT="${candidates[$((selection - 1))]}"
}

if [[ "$AUTO_BREW" -eq 1 ]]; then
  install_missing_with_brew
fi
require_or_suggest
pick_vault

if [[ ! -d "$VAULT_ROOT/.obsidian" ]]; then
  echo "Invalid vault: $VAULT_ROOT (missing .obsidian)" >&2
  exit 1
fi

args=(
  --vault "$VAULT_ROOT"
  --yazi-config "$YAZI_CONFIG_DIR"
  --cache "$CACHE_ROOT"
)

if [[ "$INSTALL_LAUNCHD" -eq 1 ]]; then
  args+=(--install-launchd)
fi
if [[ "$SKIP_NPM_INSTALL" -eq 1 ]]; then
  args+=(--skip-npm-install)
fi
if [[ "$FORCE_BUILD" -eq 1 ]]; then
  args+=(--force-build)
fi
if [[ -n "$PREBUILT_EXPECTED_SHA256" ]]; then
  args+=(--prebuilt-sha256 "$PREBUILT_EXPECTED_SHA256")
fi

echo "Running installer with:"
echo "  vault: $VAULT_ROOT"
echo "  yazi-config: $YAZI_CONFIG_DIR"
echo "  cache: $CACHE_ROOT"
if [[ "$INSTALL_LAUNCHD" -eq 1 ]]; then
  echo "  launchd: enabled"
else
  echo "  launchd: disabled"
fi
if [[ "$FORCE_BUILD" -eq 1 ]]; then
  echo "  plugin install: npm build (forced)"
elif prebuilt_is_usable; then
  echo "  plugin install: prebuilt (trusted checksum provided)"
else
  echo "  plugin install: npm build (no trusted prebuilt checksum or mismatch)"
fi

"$SCRIPT_DIR/install.sh" "${args[@]}"

echo
echo "Easy install completed."
echo "Tip: run './scripts/doctor.sh --vault \"$VAULT_ROOT\"' to verify dependencies."
