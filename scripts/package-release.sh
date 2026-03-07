#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PACK_ROOT/dist"
PLUGIN_DIR="$PACK_ROOT/obsidian-plugin/yazi-exporter"
PREBUILT_DIR="$PLUGIN_DIR/prebuilt"
PREBUILT_MAIN="$PREBUILT_DIR/main.js"
RELEASE_REF="${OBSIDIAN_RELEASE_REF:-HEAD}"
RELEASE_COMMIT=""
HEAD_COMMIT=""
RELEASE_MANIFEST_FILE="${OBSIDIAN_RELEASE_MANIFEST_FILE:-$PACK_ROOT/RELEASE_MANIFEST.txt}"

VERSION="${1:-$(date +%Y.%m.%d)}"
PKG_NAME="obsidian-yazi-render-$VERSION"
STAGE_DIR="$DIST_DIR/$PKG_NAME"
MINISIGN_SECRET_KEY="${MINISIGN_SECRET_KEY:-}"

if [[ -z "$VERSION" ]]; then
  echo "Version must not be empty" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "Invalid version: $VERSION" >&2
  echo "Allowed characters: 0-9 A-Z a-z . _ -" >&2
  exit 1
fi
if [[ "$VERSION" == *".."* ]]; then
  echo "Invalid version: path traversal sequence '..' is not allowed" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 1
fi

if ! git -C "$PACK_ROOT" diff --quiet --ignore-submodules --; then
  echo "Working tree has unstaged tracked changes. Commit or stash before packaging." >&2
  exit 1
fi
if ! git -C "$PACK_ROOT" diff --cached --quiet --ignore-submodules --; then
  echo "Working tree has staged but uncommitted changes. Commit before packaging." >&2
  exit 1
fi

HEAD_COMMIT="$(git -C "$PACK_ROOT" rev-parse --verify "HEAD^{commit}" 2>/dev/null || true)"
RELEASE_COMMIT="$(git -C "$PACK_ROOT" rev-parse --verify "${RELEASE_REF}^{commit}" 2>/dev/null || true)"
if [[ -z "$RELEASE_COMMIT" ]]; then
  echo "Invalid OBSIDIAN_RELEASE_REF (cannot resolve to commit): $RELEASE_REF" >&2
  exit 1
fi
if [[ "$RELEASE_COMMIT" != "$HEAD_COMMIT" ]]; then
  echo "OBSIDIAN_RELEASE_REF must resolve to HEAD for deterministic packaging." >&2
  echo "Resolved release ref: $RELEASE_COMMIT" >&2
  echo "Current HEAD:        $HEAD_COMMIT" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
if [[ "$STAGE_DIR" != "$DIST_DIR"/* ]]; then
  echo "Refusing to use stage dir outside dist: $STAGE_DIR" >&2
  exit 1
fi
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to build prebuilt plugin artifact" >&2
  exit 1
fi
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1 && ! command -v openssl >/dev/null 2>&1; then
  echo "A SHA-256 command is required (shasum, sha256sum, or openssl)" >&2
  exit 1
fi

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
  openssl dgst -sha256 "$file" | awk '{print $NF}' | tr -d '[:space:]'
}

allowlist_subtrees=(
  'scripts'
  'yazi'
  'obsidian-plugin/yazi-exporter/src'
  'obsidian-plugin/yazi-exporter/test'
  'obsidian-plugin/yazi-exporter/prebuilt'
)

copy_tracked_file_from_ref() {
  local rel="$1"
  local dst="$STAGE_DIR/$rel"
  mkdir -p "$(dirname "$dst")"
  if ! git -C "$PACK_ROOT" show "$RELEASE_COMMIT:$rel" > "$dst"; then
    echo "Failed to read tracked file from $RELEASE_COMMIT: $rel" >&2
    exit 1
  fi
}

collect_allowlist_noise() {
  local mode="$1"
  case "$mode" in
    untracked)
      git -C "$PACK_ROOT" ls-files --others --exclude-standard -- "${allowlist_subtrees[@]}" || true
      ;;
    ignored)
      git -C "$PACK_ROOT" ls-files --others --ignored --exclude-standard -- "${allowlist_subtrees[@]}" || true
      ;;
    *)
      return 1
      ;;
  esac
}

pre_stage_untracked_noise="$(collect_allowlist_noise untracked)"
if [[ -n "$pre_stage_untracked_noise" ]]; then
  echo "Refusing to package: untracked files found under allowlisted trees:" >&2
  printf '%s\n' "$pre_stage_untracked_noise" >&2
  exit 1
fi

pre_stage_ignored_noise="$(collect_allowlist_noise ignored)"
if [[ -n "$pre_stage_ignored_noise" ]]; then
  echo "Refusing to package: ignored files found under allowlisted trees:" >&2
  printf '%s\n' "$pre_stage_ignored_noise" >&2
  exit 1
fi

if [[ ! -f "$PLUGIN_DIR/package-lock.json" ]]; then
  echo "Missing $PLUGIN_DIR/package-lock.json; refusing non-deterministic npm install" >&2
  exit 1
fi
(cd "$PLUGIN_DIR" && npm ci --no-fund --no-audit)

mkdir -p "$PREBUILT_DIR"
(cd "$PLUGIN_DIR" && OBSIDIAN_PLUGIN_OUTDIR="$PREBUILT_DIR" npm run build)
if [[ ! -f "$PREBUILT_MAIN" ]]; then
  echo "Build output is missing: $PREBUILT_MAIN" >&2
  exit 1
fi
(
  cd "$PREBUILT_DIR"
  sha256_file main.js > main.js.sha256
)

# Verify fresh build matches committed prebuilt (detect stale artifacts before staging).
if ! git -C "$PACK_ROOT" diff --quiet -- "$PREBUILT_DIR/main.js" "$PREBUILT_DIR/main.js.sha256"; then
  echo "Fresh build differs from committed prebuilt. Commit the rebuilt artifacts before packaging." >&2
  exit 1
fi

if [[ "${SKIP_RELEASE_CHECK:-0}" != "1" ]]; then
  # Validate release readiness after regenerating prebuilt artifacts.
  OBSIDIAN_RELEASE_CHECK_SKIP_NPM_CI=1 bash "$SCRIPT_DIR/release-check.sh"
fi

# Manifest allowlist approach: copy only tracked files from a git snapshot.
allowlisted_files=""
if [[ ! -f "$RELEASE_MANIFEST_FILE" ]]; then
  echo "Missing release manifest: $RELEASE_MANIFEST_FILE" >&2
  exit 1
fi
while IFS= read -r rel; do
  rel="${rel%%$'\r'}"
  rel="${rel#"${rel%%[![:space:]]*}"}"
  rel="${rel%"${rel##*[![:space:]]}"}"
  [[ -z "$rel" ]] && continue
  [[ "$rel" == \#* ]] && continue
  if [[ "$rel" == /* || "$rel" == *".."* ]]; then
    echo "Invalid entry in release manifest: $rel" >&2
    exit 1
  fi
  if [[ "$rel" == */ ]]; then
    echo "Directory entry is not allowed in release manifest: $rel" >&2
    exit 1
  fi
  if [[ "$(git -C "$PACK_ROOT" cat-file -t "$RELEASE_COMMIT:$rel" 2>/dev/null || true)" != "blob" ]]; then
    echo "Release manifest entry is missing or not a file at $RELEASE_COMMIT: $rel" >&2
    exit 1
  fi
  allowlisted_files+="$rel"$'\n'
done < "$RELEASE_MANIFEST_FILE"
allowlisted_files="$(printf '%s' "$allowlisted_files" | LC_ALL=C sort -u)"

if [[ -z "$allowlisted_files" ]]; then
  echo "Release manifest resolved to zero files; refusing to package." >&2
  exit 1
fi

while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  copy_tracked_file_from_ref "$rel"
done <<< "$allowlisted_files"

# Defense-in-depth: fail packaging if local audit/noise artifacts appear in staged output.
stage_noise=""
while IFS= read -r noise_path; do
  [[ -z "$noise_path" ]] && continue
  stage_noise+="$noise_path"$'\n'
done < <(
  {
    find "$STAGE_DIR" -type f \( \
      -name 'AGENTS.md' -o \
      -name 'bridge*.md' -o \
      -name 'ssh*.md' -o \
      -name 'AUDIT_STATUS.md' -o \
      -name 'INVENTORY.txt' -o \
      -name '*.pem' -o \
      -name '*.ppk' -o \
      -name 'id_rsa*' -o \
      -name 'id_ed25519*' -o \
      -name 'skill*.md' \
    \) -print
    find "$STAGE_DIR" -type d \( \
      -name 'bridge' -o -name 'bridge-*' -o -name 'bridge_*' -o \
      -name 'ssh' -o -name 'ssh-*' -o -name 'ssh_*' -o -name '.ssh' -o \
      -name 'skill' -o -name 'skills' -o \
      -name 'release-audit-*' \
    \) -print
  } | sed "s|^$STAGE_DIR/||" | sort -u
)
if [[ -n "$stage_noise" ]]; then
  echo "Refusing to package local/noise artifacts detected in staging tree:" >&2
  printf '%s' "$stage_noise" >&2
  exit 1
fi

chmod +x "$STAGE_DIR/scripts/cleanup-cache.sh"
chmod +x "$STAGE_DIR/scripts/doctor.sh"
chmod +x "$STAGE_DIR/scripts/install-easy.sh"
chmod +x "$STAGE_DIR/scripts/install-launchd.sh"
chmod +x "$STAGE_DIR/scripts/install.sh"
chmod +x "$STAGE_DIR/scripts/package-release.sh"
chmod +x "$STAGE_DIR/scripts/release-check.sh"
chmod +x "$STAGE_DIR/scripts/debug-yazi-error.sh"
chmod +x "$STAGE_DIR/scripts/debug-yazi-status.sh"

tar -C "$DIST_DIR" -czf "$DIST_DIR/$PKG_NAME.tar.gz" "$PKG_NAME"
(
  cd "$DIST_DIR"
  rm -f "$PKG_NAME.zip"
  zip -qr "$PKG_NAME.zip" "$PKG_NAME"
  sha256_file "$PKG_NAME.tar.gz" > "$PKG_NAME.tar.gz.sha256"
  sha256_file "$PKG_NAME.zip" > "$PKG_NAME.zip.sha256"
)

CHECKSUMS_FILE="$DIST_DIR/$PKG_NAME.checksums.txt"
PREBUILT_HASH_FILE="$DIST_DIR/$PKG_NAME.prebuilt-main.js.sha256"
STAGED_PREBUILT_MAIN="$STAGE_DIR/obsidian-plugin/yazi-exporter/prebuilt/main.js"
if [[ ! -f "$STAGED_PREBUILT_MAIN" ]]; then
  echo "Staged prebuilt artifact missing: $STAGED_PREBUILT_MAIN" >&2
  exit 1
fi
printf '%s\n' "$(sha256_file "$STAGED_PREBUILT_MAIN")" > "$PREBUILT_HASH_FILE"
{
  printf '%s  %s\n' "$(cat "$DIST_DIR/$PKG_NAME.tar.gz.sha256")" "$PKG_NAME.tar.gz"
  printf '%s  %s\n' "$(cat "$DIST_DIR/$PKG_NAME.zip.sha256")" "$PKG_NAME.zip"
  printf '%s  %s\n' "$(sha256_file "$PREBUILT_HASH_FILE")" "$(basename "$PREBUILT_HASH_FILE")"
} > "$CHECKSUMS_FILE"

if [[ -n "$MINISIGN_SECRET_KEY" ]]; then
  if ! command -v minisign >/dev/null 2>&1; then
    echo "MINISIGN_SECRET_KEY is set, but minisign command is not available." >&2
    exit 1
  fi
  if [[ ! -f "$MINISIGN_SECRET_KEY" ]]; then
    echo "MINISIGN_SECRET_KEY does not point to a file: $MINISIGN_SECRET_KEY" >&2
    exit 1
  fi
  minisign -S -s "$MINISIGN_SECRET_KEY" -m "$CHECKSUMS_FILE" -x "$CHECKSUMS_FILE.minisig"
fi

echo "Created:"
echo "- $DIST_DIR/$PKG_NAME.tar.gz"
echo "- $DIST_DIR/$PKG_NAME.zip"
echo "- $DIST_DIR/$PKG_NAME.tar.gz.sha256"
echo "- $DIST_DIR/$PKG_NAME.zip.sha256"
echo "- $PREBUILT_HASH_FILE"
echo "- $CHECKSUMS_FILE"
if [[ -f "$CHECKSUMS_FILE.minisig" ]]; then
  echo "- $CHECKSUMS_FILE.minisig"
fi
