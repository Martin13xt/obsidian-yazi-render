#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$PACK_ROOT/obsidian-plugin/yazi-exporter"
PREBUILT_MAIN="$PLUGIN_DIR/prebuilt/main.js"

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

DEFAULT_CACHE_ROOT="$(default_cache_root)"
VAULT_ROOT="${OBSIDIAN_VAULT_ROOT:-$HOME/obsidian}"
DEFAULT_YAZI_CONFIG_DIR="${YAZI_CONFIG_HOME:-$HOME/.config/yazi}"
YAZI_CONFIG_DIR="${YAZI_CONFIG_DIR:-$DEFAULT_YAZI_CONFIG_DIR}"
CACHE_ROOT="${OBSIDIAN_YAZI_CACHE:-$DEFAULT_CACHE_ROOT}"
PREBUILT_EXPECTED_SHA256="${OBSIDIAN_PREBUILT_SHA256:-}"
BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${OBSIDIAN_YAZI_BACKUP_DIR:-$HOME/.obsidian-yazi-render-backups/$BACKUP_STAMP}"
NODE_MIN_MAJOR=20
NODE_MIN_MINOR=19
NODE_MIN_PATCH=0
NODE_MIN_VERSION="${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}.${NODE_MIN_PATCH}"
INSTALL_LAUNCHD=0
SKIP_NPM_INSTALL=0
FORCE_BUILD=0
DRY_RUN=0
SKIPPED_PREVIEWER_MERGE=0
SKIPPED_KEYMAP_MERGE=0
SOURCE_BUILD_DIR=""
SOURCE_BUILD_PREPARED=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --vault <path>            Obsidian Vault root path (default: $HOME/obsidian)
  --yazi-config <path>      Yazi config dir (default: \$YAZI_CONFIG_DIR > \$YAZI_CONFIG_HOME > $HOME/.config/yazi)
  --cache <path>            Cache dir (default: $DEFAULT_CACHE_ROOT)
  --prebuilt-sha256 <hex>   Trusted SHA-256 for prebuilt main.js (optional)
  --backup-dir <path>       Backup directory for modified files
  --install-launchd         Install daily cache cleanup via launchd (macOS)
  --skip-npm-install        Skip npm install, run build only
  --force-build             Ignore prebuilt plugin and build with npm
  --dry-run                 Validate and print planned actions without modifying files
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
    --backup-dir)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --backup-dir" >&2
        usage
        exit 1
      fi
      BACKUP_DIR="$2"
      shift 2
      ;;
    --install-launchd)
      INSTALL_LAUNCHD=1
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
    --dry-run)
      DRY_RUN=1
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

preflight_launchd_option() {
  if [[ "$INSTALL_LAUNCHD" -ne 1 ]]; then
    return 0
  fi
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "--install-launchd is macOS-only." >&2
    exit 1
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    echo "--install-launchd requires launchctl in PATH." >&2
    exit 1
  fi
}

preflight_launchd_option

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

require_node_min_version() {
  require_cmd node
  local version_raw
  version_raw="$(node -p 'process.versions.node' 2>/dev/null || true)"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$version_raw"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "${minor:-}" =~ ^[0-9]+$ ]]; then
    echo "Failed to detect Node.js version (got: ${version_raw:-unknown})." >&2
    exit 1
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
    echo "Node.js >=${NODE_MIN_VERSION} is required for source builds (found: $version_raw)." >&2
    echo "Provide --prebuilt-sha256 with a trusted hash, or upgrade Node.js." >&2
    exit 1
  fi
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

secure_chmod() {
  local mode="$1"
  shift
  if ! chmod "$mode" "$@"; then
    echo "Failed to set permissions ($mode): $*" >&2
    exit 1
  fi
}

stat_mode() {
  local target="$1"
  if stat -f '%OLp' "$target" >/dev/null 2>&1; then
    stat -f '%OLp' "$target"
  else
    stat -c '%a' "$target"
  fi
}

assert_mode() {
  local target="$1"
  local expected="$2"
  local actual
  actual="$(stat_mode "$target" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "Insecure permissions on $target: expected $expected, got ${actual:-unknown}" >&2
    exit 1
  fi
}

backup_path() {
  local target="$1"
  [[ -e "$target" ]] || return 0

  local abs
  abs="$(cd "$(dirname "$target")" && pwd -P)/$(basename "$target")"
  local backup_target
  backup_target="$(backup_path_for "$target")"

  if [[ -e "$backup_target" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$backup_target")"
  if [[ -d "$abs" ]]; then
    cp -R "$abs" "$backup_target"
  else
    cp -p "$abs" "$backup_target"
  fi
}

backup_path_for() {
  local target="$1"
  local abs rel
  abs="$(cd "$(dirname "$target")" && pwd -P)/$(basename "$target")"
  rel="${abs#/}"
  printf '%s/%s\n' "$BACKUP_DIR" "$rel"
}

assert_not_symlink_path() {
  local target="$1"
  local context="${2:-path}"
  if [[ -L "$target" ]]; then
    echo "Refusing symlinked $context: $target" >&2
    exit 1
  fi
}

assert_existing_dir_within_root() {
  local target_dir="$1"
  local root_dir="$2"
  local context="${3:-directory}"
  [[ -d "$target_dir" ]] || return 0
  [[ -d "$root_dir" ]] || return 0

  local target_real
  local root_real
  target_real="$(cd "$target_dir" && pwd -P)"
  root_real="$(cd "$root_dir" && pwd -P)"
  if [[ "$target_real" != "$root_real/"* ]]; then
    echo "Refusing $context outside root: $target_real (root: $root_real)" >&2
    exit 1
  fi
}

safe_replace_file() {
  local tmp_file="$1"
  local target_file="$2"
  local context="${3:-unknown}"
  local allow_empty="${4:-0}"
  local target_dir
  local target_base
  local staged_tmp
  if [[ ! -s "$tmp_file" && "$allow_empty" != "1" ]]; then
    rm -f "$tmp_file"
    echo "Refusing to replace $target_file with empty output ($context)." >&2
    exit 1
  fi
  target_dir="$(dirname "$target_file")"
  target_base="$(basename "$target_file")"
  if [[ -e "$target_file" ]]; then
    assert_not_symlink_path "$target_file" "$context target file"
  fi
  if [[ -e "$target_dir" ]]; then
    assert_not_symlink_path "$target_dir" "$context target directory"
  fi
  mkdir -p "$target_dir"
  assert_not_symlink_path "$target_dir" "$context target directory"

  if [[ "$(cd "$(dirname "$tmp_file")" && pwd -P)" == "$(cd "$target_dir" && pwd -P)" ]]; then
    mv "$tmp_file" "$target_file"
    return
  fi

  if ! staged_tmp="$(mktemp "$target_dir/.${target_base}.tmp.XXXXXX")"; then
    rm -f "$tmp_file"
    echo "Failed to create staging file for $target_file ($context)." >&2
    exit 1
  fi
  if ! cp "$tmp_file" "$staged_tmp"; then
    rm -f "$tmp_file" "$staged_tmp"
    echo "Failed to stage replacement for $target_file ($context)." >&2
    exit 1
  fi

  rm -f "$tmp_file"
  mv "$staged_tmp" "$target_file"
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

cleanup_source_build_artifacts() {
  if [[ -n "${SOURCE_BUILD_DIR:-}" && -d "${SOURCE_BUILD_DIR:-}" ]]; then
    rm -rf "$SOURCE_BUILD_DIR"
  fi
}
trap cleanup_source_build_artifacts EXIT

can_use_trusted_prebuilt() {
  if [[ ! -f "$PREBUILT_MAIN" ]]; then
    return 1
  fi
  if [[ -z "$PREBUILT_EXPECTED_SHA256" ]]; then
    return 1
  fi
  if [[ ! "$PREBUILT_EXPECTED_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    return 1
  fi

  local actual expected
  if ! actual="$(sha256_file "$PREBUILT_MAIN")"; then
    return 1
  fi
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
  expected="$(printf '%s' "$PREBUILT_EXPECTED_SHA256" | tr '[:upper:]' '[:lower:]')"
  [[ "$actual" == "$expected" ]]
}

prepare_source_build_artifacts() {
  if [[ "$SOURCE_BUILD_PREPARED" -eq 1 ]]; then
    return 0
  fi

  require_cmd npm
  require_node_min_version
  if [[ ! -f "$PLUGIN_DIR/package-lock.json" ]]; then
    echo "Missing $PLUGIN_DIR/package-lock.json; refusing non-deterministic npm install" >&2
    exit 1
  fi
  if [[ $SKIP_NPM_INSTALL -eq 0 ]]; then
    (cd "$PLUGIN_DIR" && npm ci --no-fund --no-audit)
  fi

  SOURCE_BUILD_DIR="$(mktemp -d)"
  if ! (cd "$PLUGIN_DIR" && OBSIDIAN_PLUGIN_OUTDIR="$SOURCE_BUILD_DIR" npm run build); then
    echo "Source build failed before applying install mutations." >&2
    exit 1
  fi

  [[ -f "$SOURCE_BUILD_DIR/main.js" ]] || { echo "Build output missing: $SOURCE_BUILD_DIR/main.js" >&2; exit 1; }
  [[ -f "$SOURCE_BUILD_DIR/manifest.json" ]] || { echo "Build output missing: $SOURCE_BUILD_DIR/manifest.json" >&2; exit 1; }
  [[ -f "$SOURCE_BUILD_DIR/styles.css" ]] || { echo "Build output missing: $SOURCE_BUILD_DIR/styles.css" >&2; exit 1; }
  SOURCE_BUILD_PREPARED=1
}

require_cmd jq
require_cmd rsync
if ! command -v curl >/dev/null 2>&1; then
  echo "Warning: curl not found. REST mode may not work until curl is installed." >&2
fi

if [[ ! -d "$VAULT_ROOT/.obsidian" ]]; then
  echo "Not a valid Obsidian Vault: $VAULT_ROOT" >&2
  echo "Expected directory: $VAULT_ROOT/.obsidian" >&2
  exit 1
fi

COMMUNITY_PLUGINS="$VAULT_ROOT/.obsidian/community-plugins.json"
if [[ -f "$COMMUNITY_PLUGINS" ]]; then
  if ! jq -e '.' "$COMMUNITY_PLUGINS" >/dev/null 2>&1; then
    echo "Invalid JSON in $COMMUNITY_PLUGINS; aborting before applying changes." >&2
    echo "Fix the file or remove it, then re-run install.sh." >&2
    exit 1
  fi
fi

yazi_config_expanded="$(expand_home_path "$YAZI_CONFIG_DIR")"
if [[ "$yazi_config_expanded" != /* ]]; then
  yazi_config_expanded="$(pwd -P)/$yazi_config_expanded"
fi
if ! YAZI_CONFIG_DIR="$(canonicalize_abs_path "$yazi_config_expanded")"; then
  echo "Refusing unsafe yazi config dir (must resolve to an absolute path): $yazi_config_expanded" >&2
  echo "Specify a dedicated yazi config directory via --yazi-config <path>." >&2
  exit 1
fi

if [[ -z "$YAZI_CONFIG_DIR" || "$YAZI_CONFIG_DIR" == "/" || "$YAZI_CONFIG_DIR" == "$HOME" ]]; then
  echo "Refusing unsafe yazi config dir: $YAZI_CONFIG_DIR" >&2
  echo "Specify a dedicated yazi config directory via --yazi-config <path>." >&2
  exit 1
fi

cache_root_expanded="$(expand_home_path "$CACHE_ROOT")"
if ! CACHE_ROOT="$(canonicalize_abs_path "$cache_root_expanded")"; then
  echo "Refusing unsafe cache root (must be an absolute path): $cache_root_expanded" >&2
  echo "Specify a dedicated absolute cache directory via --cache <path>." >&2
  exit 1
fi

if [[ -z "$CACHE_ROOT" || "$CACHE_ROOT" == "/" || "$CACHE_ROOT" == "$HOME" ]]; then
  echo "Refusing unsafe cache root: $CACHE_ROOT" >&2
  echo "Specify a dedicated cache directory via --cache <path>." >&2
  exit 1
fi

backup_dir_expanded="$(expand_home_path "$BACKUP_DIR")"
if [[ "$backup_dir_expanded" != /* ]]; then
  backup_dir_expanded="$(pwd -P)/$backup_dir_expanded"
fi
if ! BACKUP_DIR="$(canonicalize_abs_path "$backup_dir_expanded")"; then
  echo "Refusing unsafe backup dir (must resolve to an absolute path): $backup_dir_expanded" >&2
  echo "Specify a dedicated backup directory via --backup-dir <path>." >&2
  exit 1
fi

if [[ -z "$BACKUP_DIR" || "$BACKUP_DIR" == "/" || "$BACKUP_DIR" == "$HOME" ]]; then
  echo "Refusing unsafe backup dir: $BACKUP_DIR" >&2
  echo "Specify a dedicated backup directory via --backup-dir <path>." >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run mode: no files will be modified."
  echo "Vault: $VAULT_ROOT"
  echo "Yazi config: $YAZI_CONFIG_DIR"
  echo "Cache: $CACHE_ROOT"
  echo "Backup dir: $BACKUP_DIR"
  echo
  echo "Planned actions:"
  echo "- Copy yazi plugins into: $YAZI_CONFIG_DIR/plugins"
  echo "- Update yazi config files: $YAZI_CONFIG_DIR/yazi.toml and $YAZI_CONFIG_DIR/keymap.toml"
  echo "- Install Obsidian plugin into: $VAULT_ROOT/.obsidian/plugins/yazi-exporter"
  echo "- Sync yazi runtime cache fallback + exporter cacheDir"
  if [[ "$FORCE_BUILD" -eq 1 ]]; then
    echo "- Plugin install mode: source build (forced)"
  elif [[ -n "$PREBUILT_EXPECTED_SHA256" ]]; then
    echo "- Plugin install mode: prebuilt if trusted checksum matches, otherwise source build"
  else
    echo "- Plugin install mode: source build (trusted prebuilt checksum not provided)"
  fi
  echo "- Update community plugins file: $VAULT_ROOT/.obsidian/community-plugins.json"
  if [[ "$INSTALL_LAUNCHD" -eq 1 ]]; then
    echo "- Install launchd cleanup job (OBSIDIAN_YAZI_CACHE=$CACHE_ROOT)"
  fi
  exit 0
fi

NEED_SOURCE_BUILD=0
if [[ "$FORCE_BUILD" -eq 1 ]]; then
  NEED_SOURCE_BUILD=1
elif ! can_use_trusted_prebuilt; then
  NEED_SOURCE_BUILD=1
fi
if [[ "$NEED_SOURCE_BUILD" -eq 1 ]]; then
  prepare_source_build_artifacts
fi

YAZI_PLUGINS_ROOT="$YAZI_CONFIG_DIR/plugins"
VAULT_PLUGINS_ROOT="$VAULT_ROOT/.obsidian/plugins"
VAULT_PLUGIN_DIR="$VAULT_PLUGINS_ROOT/yazi-exporter"
if [[ -e "$YAZI_PLUGINS_ROOT" ]]; then
  assert_not_symlink_path "$YAZI_PLUGINS_ROOT" "yazi plugins root"
  if [[ ! -d "$YAZI_PLUGINS_ROOT" ]]; then
    echo "Refusing non-directory yazi plugins root: $YAZI_PLUGINS_ROOT" >&2
    exit 1
  fi
fi
if [[ -e "$VAULT_PLUGINS_ROOT" ]]; then
  assert_not_symlink_path "$VAULT_PLUGINS_ROOT" "vault plugins root"
  if [[ ! -d "$VAULT_PLUGINS_ROOT" ]]; then
    echo "Refusing non-directory vault plugins root: $VAULT_PLUGINS_ROOT" >&2
    exit 1
  fi
fi
if [[ -e "$VAULT_PLUGIN_DIR" ]]; then
  assert_not_symlink_path "$VAULT_PLUGIN_DIR" "vault plugin directory"
  if [[ ! -d "$VAULT_PLUGIN_DIR" ]]; then
    echo "Refusing non-directory vault plugin path: $VAULT_PLUGIN_DIR" >&2
    exit 1
  fi
  assert_existing_dir_within_root "$VAULT_PLUGIN_DIR" "$VAULT_PLUGINS_ROOT" "vault plugin directory"
fi

mkdir -p "$YAZI_CONFIG_DIR/plugins"
mkdir -p "$BACKUP_DIR"
secure_chmod 700 "$BACKUP_DIR"
mkdir -p "$CACHE_ROOT/img" "$CACHE_ROOT/mode" "$CACHE_ROOT/locks" "$CACHE_ROOT/log" "$CACHE_ROOT/requests" "$CACHE_ROOT/requests/queue"
secure_chmod 700 "$CACHE_ROOT" "$CACHE_ROOT/img" "$CACHE_ROOT/mode" "$CACHE_ROOT/locks" "$CACHE_ROOT/log" "$CACHE_ROOT/requests" "$CACHE_ROOT/requests/queue"
printf 'obsidian-yazi-cache\n' > "$CACHE_ROOT/.obsidian-yazi-cache"
secure_chmod 600 "$CACHE_ROOT/.obsidian-yazi-cache"
assert_mode "$CACHE_ROOT" 700
assert_mode "$CACHE_ROOT/img" 700
assert_mode "$CACHE_ROOT/mode" 700
assert_mode "$CACHE_ROOT/locks" 700
assert_mode "$CACHE_ROOT/log" 700
assert_mode "$CACHE_ROOT/requests" 700
assert_mode "$CACHE_ROOT/requests/queue" 700
assert_mode "$CACHE_ROOT/.obsidian-yazi-cache" 600

copy_plugin() {
  local name="$1"
  local src="$PACK_ROOT/yazi/plugins/$name"
  local dst="$YAZI_CONFIG_DIR/plugins/$name"
  local plugins_root
  local yazi_root
  local dst_canon
  local staged_dst
  local backup_copy=""

  if [[ ! -d "$src" ]]; then
    echo "Missing plugin source: $src" >&2
    exit 1
  fi

  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Unsafe plugin name: $name" >&2
    exit 1
  fi

  assert_not_symlink_path "$dst" "plugin destination"
  yazi_root="$(cd "$YAZI_CONFIG_DIR" && pwd -P)"
  plugins_root="$(cd "$YAZI_CONFIG_DIR/plugins" && pwd -P)"
  dst_canon="$(cd "$(dirname "$dst")" && pwd -P)/$(basename "$dst")"
  if [[ "$dst_canon" == "/" || "$dst_canon" == "$yazi_root" || "$dst_canon" == "$plugins_root" ]]; then
    echo "Refusing unsafe destination for plugin copy: $dst_canon" >&2
    exit 1
  fi
  if [[ "$dst_canon" != "$plugins_root/"* ]]; then
    echo "Plugin destination escapes plugins dir: $dst_canon" >&2
    exit 1
  fi
  if [[ -e "$dst" && ! -d "$dst" ]]; then
    echo "Refusing to replace non-directory path: $dst" >&2
    exit 1
  fi
  assert_existing_dir_within_root "$dst" "$plugins_root" "plugin destination"

  staged_dst="$(mktemp -d "$plugins_root/.${name}.staged.XXXXXX")"
  cp -R "$src"/. "$staged_dst"/
  backup_path "$dst"
  backup_copy="$(backup_path_for "$dst")"

  if [[ -d "$dst" ]]; then
    # Keep destination directory in place to avoid a missing-path window.
    if ! rsync -a --delete "$staged_dst"/ "$dst"/; then
      rm -rf "$staged_dst"
      if [[ -d "$backup_copy" ]]; then
        rm -rf "$dst"
        mkdir -p "$dst"
        cp -R "$backup_copy"/. "$dst"/
      fi
      echo "Failed to sync plugin directory: $dst" >&2
      exit 1
    fi
    rm -rf "$staged_dst"
    return
  fi

  if ! mv "$staged_dst" "$dst"; then
    rm -rf "$staged_dst"
    echo "Failed to install plugin directory: $dst" >&2
    exit 1
  fi
}

copy_plugin "obsidian-common.yazi"
copy_plugin "obsidian-preview.yazi"
copy_plugin "obsidian-toggle.yazi"
copy_plugin "obsidian-nav.yazi"
copy_plugin "obsidian-refresh.yazi"
copy_plugin "obsidian-tune.yazi"

if [[ "$VAULT_ROOT" == *$'\n'* || "$VAULT_ROOT" == *$'\r'* ]]; then
  echo "Invalid vault path: newline characters are not allowed" >&2
  exit 1
fi

escaped_vault_root="$VAULT_ROOT"
escaped_vault_root="${escaped_vault_root//\\/\\\\}"
escaped_vault_root="${escaped_vault_root//\"/\\\"}"
escaped_vault_root="${escaped_vault_root//&/\\&}"
escaped_vault_root="${escaped_vault_root//|/\\|}"
escaped_vault_root="${escaped_vault_root//\//\\/}"
escaped_vault_root="${escaped_vault_root//[/\\[}"
escaped_vault_root="${escaped_vault_root//]/\\]}"
escaped_vault_root="${escaped_vault_root//\$/\\$}"
escaped_vault_root="${escaped_vault_root//./\\.}"
escaped_vault_root="${escaped_vault_root//\*/\\*}"
escaped_vault_root="${escaped_vault_root//^/\\^}"

if [[ "$CACHE_ROOT" == *$'\n'* || "$CACHE_ROOT" == *$'\r'* ]]; then
  echo "Invalid cache path: newline characters are not allowed" >&2
  exit 1
fi
escaped_cache_root="$CACHE_ROOT"
escaped_cache_root="${escaped_cache_root//\\/\\\\}"
escaped_cache_root="${escaped_cache_root//\"/\\\"}"
escaped_cache_root="${escaped_cache_root//&/\\&}"
escaped_cache_root="${escaped_cache_root//|/\\|}"
escaped_cache_root="${escaped_cache_root//\//\\/}"
escaped_cache_root="${escaped_cache_root//[/\\[}"
escaped_cache_root="${escaped_cache_root//]/\\]}"
escaped_cache_root="${escaped_cache_root//\$/\\$}"
escaped_cache_root="${escaped_cache_root//./\\.}"
escaped_cache_root="${escaped_cache_root//\*/\\*}"
escaped_cache_root="${escaped_cache_root//^/\\^}"
# Only obsidian-common.yazi holds vault/cache defaults; other plugins call C.vault_root() / C.cache_root().
tmp_lua="$(mktemp)"
sed \
  -e "s|local default = (home ~= \"\") and (home \\.\\. \"/obsidian\") or \"/obsidian\"|local default = \"$escaped_vault_root\"|g" \
  -e "s|C\\.env(\"OBSIDIAN_YAZI_CACHE\", C\\.default_cache_root())|C.env(\"OBSIDIAN_YAZI_CACHE\", \"$escaped_cache_root\")|g" \
  "$YAZI_CONFIG_DIR/plugins/obsidian-common.yazi/main.lua" > "$tmp_lua"
safe_replace_file "$tmp_lua" "$YAZI_CONFIG_DIR/plugins/obsidian-common.yazi/main.lua" "bake vault/cache defaults"

upsert_managed_block() {
  local file="$1"
  local snippet="$2"
  local start_marker="$3"
  local end_marker="$4"
  local context="$5"
  local tmp
  local snippet_file
  tmp="$(mktemp)"
  snippet_file="$(mktemp)"
  printf '%s\n' "$snippet" > "$snippet_file"

  touch "$file"
  if grep -qF "$start_marker" "$file" && grep -qF "$end_marker" "$file"; then
    awk -v start="$start_marker" -v end="$end_marker" -v block_file="$snippet_file" '
      BEGIN { inside = 0; replaced = 0 }
      function print_block() {
        while ((getline line < block_file) > 0) {
          print line
        }
        close(block_file)
      }
      $0 == start {
        if (!replaced) {
          print_block()
          replaced = 1
        }
        inside = 1
        next
      }
      $0 == end {
        inside = 0
        next
      }
      !inside { print }
      END {
        if (!replaced) {
          print ""
          print_block()
        }
      }
    ' "$file" > "$tmp"
    rm -f "$snippet_file"
    safe_replace_file "$tmp" "$file" "$context"
    return
  fi

  printf "\n%s\n" "$snippet" >> "$file"
  rm -f "$snippet_file"
}

has_assignment_conflict_outside_managed_block() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local dotted_regex="$4"
  local table="$5"
  local key="$6"

  awk -v start="$start_marker" -v end="$end_marker" -v dotted="$dotted_regex" -v table="$table" -v key="$key" '
    function ltrim(s) { sub(/^[ \t\r]+/, "", s); return s }
    function rtrim(s) { sub(/[ \t\r]+$/, "", s); return s }
    function trim(s)  { return rtrim(ltrim(s)) }
    BEGIN { in_table = 0; inside_managed = 0; found = 0 }
    {
      line = $0
      sub(/[ \t]*#.*/, "", line)
      line = trim(line)
      if (line == "") next

      if (line == start) {
        inside_managed = 1
        in_table = 0
        next
      }
      if (line == end) {
        inside_managed = 0
        in_table = 0
        next
      }
      if (inside_managed) next

      if (line ~ ("^" dotted "[ \t]*=")) {
        found = 1
        exit 0
      }

      if (line ~ /^\[\[[^]]+\]\]$/) {
        in_table = 0
        next
      }

      if (line ~ /^\[[^]]+\]$/) {
        header = line
        sub(/^\[/, "", header)
        sub(/\]$/, "", header)
        header = trim(header)
        in_table = (header == table)
        next
      }

      if (in_table && line ~ ("^(\"" key "\"|" key ")[ \t]*=")) {
        found = 1
        exit 0
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

detect_managed_block_conflicts() {
  local yazi_file="$1"
  local keymap_file="$2"

  SKIPPED_PREVIEWER_MERGE=0
  SKIPPED_KEYMAP_MERGE=0

  if has_assignment_conflict_outside_managed_block \
    "$yazi_file" \
    '# obsidian-yazi-render:previewer:start' \
    '# obsidian-yazi-render:previewer:end' \
    'plugin\\.prepend_previewers' \
    'plugin' \
    'prepend_previewers'; then
    SKIPPED_PREVIEWER_MERGE=1
    echo "Error: $yazi_file defines plugin.prepend_previewers outside the managed block." >&2
    echo "Managed previewer block cannot be merged safely. Please merge yazi/yazi.toml.snippet manually." >&2
  fi

  if has_assignment_conflict_outside_managed_block \
    "$keymap_file" \
    '# obsidian-yazi-render:custom-keys:start' \
    '# obsidian-yazi-render:custom-keys:end' \
    'mgr\\.prepend_keymap' \
    'mgr' \
    'prepend_keymap'; then
    SKIPPED_KEYMAP_MERGE=1
    echo "Error: $keymap_file defines mgr.prepend_keymap outside the managed block." >&2
    echo "Managed keymap block cannot be merged safely. Please merge yazi/keymap.toml.snippet manually." >&2
  fi
}

upsert_yazi_previewer_block() {
  local file="$1"
  local snippet="$2"
  local start_marker='# obsidian-yazi-render:previewer:start'
  local end_marker='# obsidian-yazi-render:previewer:end'
  upsert_managed_block "$file" "$snippet" "$start_marker" "$end_marker" "upsert yazi previewer block"
}

upsert_keymap_block() {
  local file="$1"
  local snippet="$2"
  local start_marker='# obsidian-yazi-render:custom-keys:start'
  local end_marker='# obsidian-yazi-render:custom-keys:end'
  local legacy_marker='# obsidian-yazi-render:custom-keys'
  local tmp

  touch "$file"
  if grep -Fxq "$legacy_marker" "$file"; then
    tmp="$(mktemp)"
    awk '
      BEGIN { inside = 0 }
      $0 == "# obsidian-yazi-render:custom-keys" {
        inside = 1
        next
      }
      inside {
        if ($0 ~ /^[[:space:]]*]$/) {
          inside = 0
        }
        next
      }
      { print }
    ' "$file" > "$tmp"
    safe_replace_file "$tmp" "$file" "remove legacy keymap block" 1
  fi

  upsert_managed_block "$file" "$snippet" "$start_marker" "$end_marker" "upsert keymap block"
}

strip_legacy_obsidian_key_lines() {
  local file="$1"
  local start_marker='# obsidian-yazi-render:custom-keys:start'
  local end_marker='# obsidian-yazi-render:custom-keys:end'
  local tmp
  tmp="$(mktemp)"

  touch "$file"
  awk -v start="$start_marker" -v end="$end_marker" '
    BEGIN { inside = 0 }
    $0 == start {
      inside = 1
      print
      next
    }
    $0 == end {
      inside = 0
      print
      next
    }
    {
      # Non-destructive policy:
      # only remove lines that were explicitly marked by old installers.
      if (!inside && $0 ~ /#[[:space:]]*obsidian-yazi-render:(legacy|managed)([[:space:]]|$)/) {
        next
      }
      print
    }
  ' "$file" > "$tmp"
  safe_replace_file "$tmp" "$file" "strip legacy obsidian key lines" 1
}

enforce_mgr_shift_nav_bindings() {
  local file="$1"
  # Deprecated: keep installer non-destructive by avoiding direct edits to
  # existing [mgr].keymap arrays. Managed key bindings are handled only via
  # the dedicated snippet block.
  : "$file"
}

backup_path "$YAZI_CONFIG_DIR/yazi.toml"
backup_path "$YAZI_CONFIG_DIR/keymap.toml"
touch "$YAZI_CONFIG_DIR/yazi.toml" "$YAZI_CONFIG_DIR/keymap.toml"
detect_managed_block_conflicts "$YAZI_CONFIG_DIR/yazi.toml" "$YAZI_CONFIG_DIR/keymap.toml"
if [[ "$SKIPPED_PREVIEWER_MERGE" -eq 1 || "$SKIPPED_KEYMAP_MERGE" -eq 1 ]]; then
  echo "Install aborted: existing yazi config uses assignment forms that conflict with managed blocks." >&2
  echo "Resolve manually, then re-run install.sh." >&2
  exit 1
fi

upsert_yazi_previewer_block \
  "$YAZI_CONFIG_DIR/yazi.toml" \
  "$(cat "$PACK_ROOT/yazi/yazi.toml.snippet")"

strip_legacy_obsidian_key_lines "$YAZI_CONFIG_DIR/keymap.toml"
upsert_keymap_block \
  "$YAZI_CONFIG_DIR/keymap.toml" \
  "$(cat "$PACK_ROOT/yazi/keymap.toml.snippet")"

assert_not_symlink_path "$VAULT_PLUGINS_ROOT" "vault plugins root"
mkdir -p "$VAULT_PLUGINS_ROOT"
assert_not_symlink_path "$VAULT_PLUGIN_DIR" "vault plugin directory"
if [[ -d "$VAULT_PLUGIN_DIR" ]]; then
  assert_existing_dir_within_root "$VAULT_PLUGIN_DIR" "$VAULT_PLUGINS_ROOT" "vault plugin directory"
else
  mkdir -p "$VAULT_PLUGIN_DIR"
fi

install_prebuilt_plugin() {
  backup_path "$VAULT_PLUGIN_DIR/main.js"
  backup_path "$VAULT_PLUGIN_DIR/manifest.json"
  backup_path "$VAULT_PLUGIN_DIR/styles.css"
  local tmp_main
  local tmp_manifest
  local tmp_styles
  tmp_main="$(mktemp)"
  tmp_manifest="$(mktemp)"
  tmp_styles="$(mktemp)"
  cp "$PREBUILT_MAIN" "$tmp_main"
  cp "$PLUGIN_DIR/manifest.json" "$tmp_manifest"
  cp "$PLUGIN_DIR/styles.css" "$tmp_styles"
  safe_replace_file "$tmp_main" "$VAULT_PLUGIN_DIR/main.js" "install prebuilt main.js"
  safe_replace_file "$tmp_manifest" "$VAULT_PLUGIN_DIR/manifest.json" "install prebuilt manifest.json"
  safe_replace_file "$tmp_styles" "$VAULT_PLUGIN_DIR/styles.css" "install prebuilt styles.css"
}

sync_exporter_cache_dir_setting() {
  local data_file="$VAULT_PLUGIN_DIR/data.json"
  local tmp_json
  tmp_json="$(mktemp)"

  backup_path "$data_file"
  if [[ -f "$data_file" ]]; then
    if ! jq --arg cache "$CACHE_ROOT" '
      if type=="object" then . else {} end
      | .cacheDir = $cache
    ' "$data_file" > "$tmp_json" 2>/dev/null; then
      echo "Warning: invalid JSON in $data_file; replacing with cacheDir-only config." >&2
      jq -n --arg cache "$CACHE_ROOT" '{cacheDir: $cache}' > "$tmp_json"
    fi
  else
    jq -n --arg cache "$CACHE_ROOT" '{cacheDir: $cache}' > "$tmp_json"
  fi

  safe_replace_file "$tmp_json" "$data_file" "sync exporter cacheDir"
}

install_built_plugin() {
  if [[ "$SOURCE_BUILD_PREPARED" -ne 1 || -z "$SOURCE_BUILD_DIR" ]]; then
    echo "Internal error: source build artifacts are unavailable." >&2
    exit 1
  fi
  backup_path "$VAULT_PLUGIN_DIR/main.js"
  backup_path "$VAULT_PLUGIN_DIR/manifest.json"
  backup_path "$VAULT_PLUGIN_DIR/styles.css"
  local tmp_main
  local tmp_manifest
  local tmp_styles
  tmp_main="$(mktemp)"
  tmp_manifest="$(mktemp)"
  tmp_styles="$(mktemp)"
  cp "$SOURCE_BUILD_DIR/main.js" "$tmp_main"
  cp "$SOURCE_BUILD_DIR/manifest.json" "$tmp_manifest"
  cp "$SOURCE_BUILD_DIR/styles.css" "$tmp_styles"
  safe_replace_file "$tmp_main" "$VAULT_PLUGIN_DIR/main.js" "install built main.js"
  safe_replace_file "$tmp_manifest" "$VAULT_PLUGIN_DIR/manifest.json" "install built manifest.json"
  safe_replace_file "$tmp_styles" "$VAULT_PLUGIN_DIR/styles.css" "install built styles.css"
}

verify_prebuilt_checksum() {
  # Trust boundary: require an externally provided checksum, not a co-located file.
  if [[ -z "$PREBUILT_EXPECTED_SHA256" ]]; then
    echo "Warning: trusted prebuilt checksum not provided; using source build." >&2
    echo "Set --prebuilt-sha256 (or OBSIDIAN_PREBUILT_SHA256) from a trusted release checksum to allow prebuilt install." >&2
    return 1
  fi
  if [[ ! "$PREBUILT_EXPECTED_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    echo "Warning: invalid --prebuilt-sha256 value; expected 64 hex chars. Using source build." >&2
    return 1
  fi

  local actual
  if ! actual="$(sha256_file "$PREBUILT_MAIN")"; then
    echo "Warning: no SHA-256 command found (shasum/sha256sum/openssl); falling back to source build." >&2
    return 1
  fi
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
  local expected
  expected="$(printf '%s' "$PREBUILT_EXPECTED_SHA256" | tr '[:upper:]' '[:lower:]')"
  if [[ "$expected" != "$actual" ]]; then
    echo "Warning: prebuilt checksum mismatch; falling back to source build." >&2
    return 1
  fi
  return 0
}

PLUGIN_INSTALL_MODE="prebuilt"
LAUNCHD_STATUS="skipped"
if [[ $FORCE_BUILD -eq 1 ]]; then
  PLUGIN_INSTALL_MODE="build"
  install_built_plugin
elif [[ -f "$PREBUILT_MAIN" ]] && verify_prebuilt_checksum; then
  install_prebuilt_plugin
else
  PLUGIN_INSTALL_MODE="build"
  install_built_plugin
fi

sync_exporter_cache_dir_setting

if [[ -f "$COMMUNITY_PLUGINS" ]]; then
  backup_path "$COMMUNITY_PLUGINS"
  tmp_json="$(mktemp)"
  jq 'if type=="array" then . else [] end | . + ["yazi-exporter"] | unique' "$COMMUNITY_PLUGINS" > "$tmp_json"
  safe_replace_file "$tmp_json" "$COMMUNITY_PLUGINS" "update community plugins list"
else
  echo '["yazi-exporter"]' > "$COMMUNITY_PLUGINS"
fi

if [[ $INSTALL_LAUNCHD -eq 1 ]]; then
  if OBSIDIAN_YAZI_BACKUP_DIR="$BACKUP_DIR" OBSIDIAN_YAZI_CACHE="$CACHE_ROOT" "$SCRIPT_DIR/install-launchd.sh"; then
    LAUNCHD_STATUS="installed"
  else
    LAUNCHD_STATUS="failed (core install kept)"
    echo "Warning: launchd setup failed, but core install completed." >&2
    echo "Run install-launchd.sh manually after fixing launchctl/permissions." >&2
  fi
fi

echo
echo "Install completed."
echo "Vault: $VAULT_ROOT"
echo "Yazi config: $YAZI_CONFIG_DIR"
echo "Cache: $CACHE_ROOT"
echo "Backups: $BACKUP_DIR"
echo "Plugin install mode: $PLUGIN_INSTALL_MODE"
echo "Launchd cleanup: $LAUNCHD_STATUS"
echo
echo "Minimum setup checklist:"
echo "1) Default REST path: enable the Local REST API plugin and set an API key"
echo "2) Optional: enable Advanced URI plugin for URI fallback"
echo "3) If preview does not update, run: $PACK_ROOT/scripts/doctor.sh --vault \"$VAULT_ROOT\""
echo
echo "Next steps:"
echo "1) Restart Obsidian"
echo "2) Restart yazi"
echo "3) Hover a .md file to trigger PNG preview"
echo "4) Use J/K or ,j/,k (paging), R or ,p (toggle), U or ,u (refresh), ,= / ,- / ,0 (live zoom)"
echo
echo "Rollback:"
echo "1) Inspect backups under: $BACKUP_DIR"
echo "2) Restore needed files back to their original locations"
if [[ $INSTALL_LAUNCHD -eq 1 ]]; then
  LAUNCHD_LABEL="${OBSIDIAN_YAZI_LAUNCHD_LABEL:-com.obsidian-yazi-cache-cleanup}"
  LAUNCHD_PLIST="${OBSIDIAN_YAZI_PLIST_DEST:-$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist}"
  echo "3) launchd rollback: restore $LAUNCHD_PLIST (if backed up) or unload via launchctl bootout gui/$(id -u)/$LAUNCHD_LABEL"
fi
