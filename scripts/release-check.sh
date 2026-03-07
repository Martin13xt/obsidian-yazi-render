#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="$PACK_ROOT/obsidian-plugin/yazi-exporter"
PREBUILT_MAIN="$PLUGIN_DIR/prebuilt/main.js"
PREBUILT_SUM="$PLUGIN_DIR/prebuilt/main.js.sha256"

SKIP_PLUGIN_BUILD="${OBSIDIAN_RELEASE_CHECK_SKIP_BUILD:-0}"
SKIP_NPM_CI="${OBSIDIAN_RELEASE_CHECK_SKIP_NPM_CI:-0}"
SKIP_TYPECHECK="${OBSIDIAN_RELEASE_CHECK_SKIP_TYPECHECK:-0}"
SKIP_TEST="${OBSIDIAN_RELEASE_CHECK_SKIP_TEST:-0}"
SKIP_PREBUILT_SYNC="${OBSIDIAN_RELEASE_CHECK_SKIP_PREBUILT_SYNC:-0}"
STRICT_LUA="${OBSIDIAN_RELEASE_CHECK_STRICT_LUA:-1}"
STRICT_NOISE="${OBSIDIAN_RELEASE_CHECK_STRICT_NOISE:-1}"
STRICT_WORKTREE="${OBSIDIAN_RELEASE_CHECK_STRICT_WORKTREE:-1}"

ok() { printf '[OK] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

path_remove_dir() {
  local input_path="$1"
  local remove_dir="$2"
  local output=""
  local part
  IFS=':' read -r -a _parts <<< "$input_path"
  for part in "${_parts[@]}"; do
    [[ -z "$part" ]] && continue
    if [[ "$part" == "$remove_dir" ]]; then
      continue
    fi
    if [[ -z "$output" ]]; then
      output="$part"
    else
      output="$output:$part"
    fi
  done
  printf '%s\n' "$output"
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

info "Running release checks in $PACK_ROOT"

require_cmd bash
require_cmd git

if [[ "$STRICT_WORKTREE" == "1" ]]; then
  info "Checking tracked worktree is clean"
  if ! git -C "$PACK_ROOT" diff --quiet --ignore-submodules --; then
    die "Tracked unstaged changes detected. Commit or stash before release checks."
  fi
  if ! git -C "$PACK_ROOT" diff --cached --quiet --ignore-submodules --; then
    die "Tracked staged-but-uncommitted changes detected. Commit before release checks."
  fi
  ok "Tracked worktree is clean"
fi

info "Checking required release files"
required_files=(
  "RELEASE_MANIFEST.txt"
  "README.md"
  "README.ja.md"
  "CHANGELOG.md"
  "SECURITY.md"
  "SUPPORT.md"
  "TECHNICAL_DETAILS.md"
  "CROSS_PLATFORM_INSTALL_PLAN.md"
  "LICENSE"
  "scripts/cleanup-cache.ps1"
  "yazi/yazi.toml.snippet"
  "yazi/keymap.toml.snippet"
  "obsidian-plugin/yazi-exporter/esbuild.mjs"
  "obsidian-plugin/yazi-exporter/styles.css"
  "obsidian-plugin/yazi-exporter/tsconfig.json"
  "obsidian-plugin/yazi-exporter/src/request-helpers.ts"
  "obsidian-plugin/yazi-exporter/test/request-helpers.test.ts"
  "obsidian-plugin/yazi-exporter/prebuilt/main.js"
  "obsidian-plugin/yazi-exporter/prebuilt/main.js.sha256"
  "obsidian-plugin/yazi-exporter/prebuilt/manifest.json"
)
for rel in "${required_files[@]}"; do
  [[ -f "$PACK_ROOT/$rel" ]] || die "Missing required file: $rel"
done
ok "Required release files exist"

info "Checking explicit release manifest"
manifest_file="$PACK_ROOT/RELEASE_MANIFEST.txt"
manifest_entries="$(awk '
  { sub(/\r$/, "", $0) }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  {
    gsub(/^[[:space:]]+/, "", $0)
    gsub(/[[:space:]]+$/, "", $0)
    print $0
  }
' "$manifest_file" | LC_ALL=C sort -u)"
[[ -n "$manifest_entries" ]] || die "Release manifest is empty: $manifest_file"

while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  if [[ "$rel" == /* || "$rel" == *".."* || "$rel" == */ ]]; then
    die "Invalid release manifest entry: $rel"
  fi
  if ! git -C "$PACK_ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    die "Release manifest entry is not a tracked file: $rel"
  fi
  [[ -f "$PACK_ROOT/$rel" ]] || die "Release manifest entry is not a regular file: $rel"
done <<< "$manifest_entries"

manifest_tmp="$(mktemp)"
manifest_tracked_subtrees_tmp="$(mktemp)"
tracked_subtrees_tmp="$(mktemp)"
printf '%s\n' "$manifest_entries" > "$manifest_tmp"
grep -E '^(scripts|yazi|obsidian-plugin/yazi-exporter)/' "$manifest_tmp" | LC_ALL=C sort -u > "$manifest_tracked_subtrees_tmp" || true
git -C "$PACK_ROOT" ls-files -- scripts yazi obsidian-plugin/yazi-exporter | LC_ALL=C sort -u > "$tracked_subtrees_tmp"

manifest_missing_tracked="$(comm -23 "$tracked_subtrees_tmp" "$manifest_tracked_subtrees_tmp" || true)"
if [[ -n "$manifest_missing_tracked" ]]; then
  rm -f "$manifest_tmp" "$manifest_tracked_subtrees_tmp" "$tracked_subtrees_tmp"
  die "Tracked files under release subtrees are missing from RELEASE_MANIFEST.txt:
$manifest_missing_tracked"
fi
rm -f "$manifest_tmp" "$manifest_tracked_subtrees_tmp" "$tracked_subtrees_tmp"
ok "Release manifest is explicit and covers tracked release subtrees"

info "Checking shell script syntax (bash -n)"
for f in "$PACK_ROOT"/scripts/*.sh; do
  bash -n "$f"
done
ok "Shell scripts parsed successfully"

info "Checking JSON syntax"
if command -v node >/dev/null 2>&1; then
  node - "$PACK_ROOT" <<'EOF'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const files = [
  "obsidian-plugin/yazi-exporter/manifest.json",
  "obsidian-plugin/yazi-exporter/package.json",
  "obsidian-plugin/yazi-exporter/tsconfig.json",
  "obsidian-plugin/yazi-exporter/prebuilt/manifest.json",
];
for (const rel of files) {
  const full = path.join(root, rel);
  const data = fs.readFileSync(full, "utf8");
  JSON.parse(data);
}
EOF
  ok "JSON files parsed successfully"
else
  warn "node is not available; skipped JSON syntax check"
fi

info "Checking plugin version consistency"
if command -v node >/dev/null 2>&1; then
  node - "$PACK_ROOT" <<'EOF'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const files = {
  manifest: "obsidian-plugin/yazi-exporter/manifest.json",
  pkg: "obsidian-plugin/yazi-exporter/package.json",
  lock: "obsidian-plugin/yazi-exporter/package-lock.json",
  prebuiltManifest: "obsidian-plugin/yazi-exporter/prebuilt/manifest.json",
};
const read = (rel) => JSON.parse(fs.readFileSync(path.join(root, rel), "utf8"));
const manifest = read(files.manifest);
const pkg = read(files.pkg);
const lock = read(files.lock);
const prebuiltManifest = read(files.prebuiltManifest);

const expectedVersion = manifest.version;
const expectedId = manifest.id;
const errors = [];

if (pkg.version !== expectedVersion) {
  errors.push(`package.json version mismatch: ${pkg.version} != ${expectedVersion}`);
}
if (lock.version !== expectedVersion) {
  errors.push(`package-lock.json version mismatch: ${lock.version} != ${expectedVersion}`);
}
if (prebuiltManifest.version !== expectedVersion) {
  errors.push(`prebuilt/manifest.json version mismatch: ${prebuiltManifest.version} != ${expectedVersion}`);
}
if (pkg.name !== expectedId) {
  errors.push(`package.json name mismatch: ${pkg.name} != ${expectedId}`);
}
if (prebuiltManifest.id !== expectedId) {
  errors.push(`prebuilt/manifest.json id mismatch: ${prebuiltManifest.id} != ${expectedId}`);
}

if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}
EOF
  ok "Plugin version metadata is consistent"
else
  warn "node is not available; skipped plugin version consistency check"
fi

if [[ "$SKIP_NPM_CI" != "1" || "$SKIP_TYPECHECK" != "1" || "$SKIP_TEST" != "1" || "$SKIP_PLUGIN_BUILD" != "1" ]]; then
  require_cmd npm
fi

if [[ "$SKIP_NPM_CI" != "1" ]]; then
  if [[ ! -f "$PLUGIN_DIR/package-lock.json" ]]; then
    die "Missing $PLUGIN_DIR/package-lock.json; refusing non-deterministic npm install"
  fi
  info "Installing Obsidian plugin dependencies (npm ci)"
  npm --prefix "$PLUGIN_DIR" ci --no-fund --no-audit >/dev/null
  ok "Obsidian plugin dependencies installed"
else
  info "Skipping npm ci (OBSIDIAN_RELEASE_CHECK_SKIP_NPM_CI=1)"
fi

info "Checking Lua syntax"
if command -v luac >/dev/null 2>&1; then
  for f in "$PACK_ROOT"/yazi/plugins/*/main.lua; do
    luac -p "$f"
  done
  ok "Lua files parsed successfully (luac)"
elif command -v lua >/dev/null 2>&1; then
  for f in "$PACK_ROOT"/yazi/plugins/*/main.lua; do
    lua -e "assert(loadfile('$f'))"
  done
  ok "Lua files parsed successfully (lua)"
elif command -v npm >/dev/null 2>&1 && [[ -d "$PLUGIN_DIR/node_modules" ]]; then
  for f in "$PACK_ROOT"/yazi/plugins/*/main.lua; do
    npm --prefix "$PLUGIN_DIR" exec -- luaparse "$f" >/dev/null
  done
  ok "Lua files parsed successfully (luaparse via pinned devDependency)"
else
  if [[ "$STRICT_LUA" == "1" ]]; then
    die "Lua parser is unavailable (need luac/lua, or npm ci to use pinned luaparse)."
  fi
  warn "Lua parser is unavailable (luac/lua and local luaparse). Skipping Lua syntax check."
fi

if [[ "$SKIP_TYPECHECK" != "1" ]]; then
  info "Running Obsidian plugin typecheck"
  npm --prefix "$PLUGIN_DIR" run typecheck >/dev/null
  ok "Obsidian plugin typecheck succeeded"
else
  info "Skipping typecheck (OBSIDIAN_RELEASE_CHECK_SKIP_TYPECHECK=1)"
fi

if [[ "$SKIP_TEST" != "1" ]]; then
  info "Running Obsidian plugin unit tests"
  npm --prefix "$PLUGIN_DIR" run test >/dev/null
  ok "Obsidian plugin unit tests succeeded"
else
  info "Skipping tests (OBSIDIAN_RELEASE_CHECK_SKIP_TEST=1)"
fi

if [[ "$SKIP_PLUGIN_BUILD" != "1" ]]; then
  info "Building Obsidian plugin"
  tmp_build_out="$(mktemp -d)"
  cleanup_tmp_build_out() {
    if [[ -n "${tmp_build_out:-}" && -d "${tmp_build_out:-}" ]]; then
      rm -rf "$tmp_build_out"
    fi
  }
  trap cleanup_tmp_build_out EXIT
  OBSIDIAN_PLUGIN_OUTDIR="$tmp_build_out" npm --prefix "$PLUGIN_DIR" run build >/dev/null

  if [[ "$SKIP_PREBUILT_SYNC" != "1" ]]; then
    tmp_main="$tmp_build_out/main.js"
    [[ -f "$tmp_main" ]] || die "Build output is missing: $tmp_main"
    [[ -f "$PREBUILT_MAIN" ]] || die "Prebuilt artifact is missing: $PREBUILT_MAIN"
    [[ -f "$PREBUILT_SUM" ]] || die "Prebuilt checksum file is missing: $PREBUILT_SUM"

    tmp_sum="$(sha256_file "$tmp_main" || true)"
    prebuilt_sum="$(sha256_file "$PREBUILT_MAIN" || true)"
    [[ -n "$tmp_sum" ]] || die "Unable to compute SHA-256 for $tmp_main"
    [[ -n "$prebuilt_sum" ]] || die "Unable to compute SHA-256 for $PREBUILT_MAIN"

    expected_prebuilt_sum="$(awk '{print $1}' "$PREBUILT_SUM" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    if [[ "$prebuilt_sum" != "$expected_prebuilt_sum" ]]; then
      die "prebuilt/main.js.sha256 does not match prebuilt/main.js. Regenerate prebuilt artifacts."
    fi

    if [[ "$tmp_sum" != "$prebuilt_sum" ]]; then
      die "Prebuilt artifact is stale vs source build. Run scripts/package-release.sh (or rebuild prebuilt/main.js) before release."
    fi
    ok "Prebuilt artifact matches source build"
  else
    info "Skipping prebuilt/source sync check (OBSIDIAN_RELEASE_CHECK_SKIP_PREBUILT_SYNC=1)"
  fi

  cleanup_tmp_build_out
  trap - EXIT
  ok "Obsidian plugin build succeeded"
else
  info "Skipping plugin build (OBSIDIAN_RELEASE_CHECK_SKIP_BUILD=1)"
fi

info "Running installer config-merge smoke tests"
if ! command -v jq >/dev/null 2>&1; then
  warn "Skipping installer smoke tests: jq is unavailable"
elif ! command -v rsync >/dev/null 2>&1; then
  warn "Skipping installer smoke tests: rsync is unavailable"
else
  python_cmd=""
  if command -v python3 >/dev/null 2>&1; then
    python_cmd="python3"
  elif command -v python >/dev/null 2>&1; then
    python_cmd="python"
  fi
  [[ -n "$python_cmd" ]] || die "Installer smoke tests require python (python3 or python)"

  trusted_prebuilt_sum="$(sha256_file "$PREBUILT_MAIN" || true)"
  [[ -n "$trusted_prebuilt_sum" ]] || die "Unable to compute SHA-256 for installer smoke test"

  installer_smoke_root="$(mktemp -d)"
  cleanup_installer_smoke() {
    if [[ -n "${installer_smoke_root:-}" && -d "${installer_smoke_root:-}" ]]; then
      rm -rf "$installer_smoke_root"
    fi
  }
  trap cleanup_installer_smoke EXIT

  # Case 1: existing array-of-tables configs should remain parseable.
  case1_root="$installer_smoke_root/case1-existing-array-of-tables"
  case1_vault="$case1_root/vault"
  case1_yazi="$case1_root/yazi"
  case1_cache="$case1_root/cache"
  case1_backup="$case1_root/backups"
  mkdir -p "$case1_vault/.obsidian" "$case1_yazi"
  printf '[]\n' > "$case1_vault/.obsidian/community-plugins.json"
  cat > "$case1_yazi/yazi.toml" <<'EOF'
[preview]
image_delay = 12

[[plugin.prepend_previewers]]
url = "*.txt"
run = "noop-preview"
EOF
  cat > "$case1_yazi/keymap.toml" <<'EOF'
[[mgr.prepend_keymap]]
on = "x"
run = "noop"
desc = "existing map"
EOF
  bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case1_vault" \
    --yazi-config "$case1_yazi" \
    --cache "$case1_cache" \
    --backup-dir "$case1_backup" \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install >/dev/null

  "$python_cmd" - "$case1_yazi/yazi.toml" "$case1_yazi/keymap.toml" <<'PY'
import pathlib
import sys
try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore

for target in sys.argv[1:]:
    data = pathlib.Path(target).read_text(encoding="utf-8")
    tomllib.loads(data)
PY

  # Case 2: conflicting table-scoped assignments should fail safely.
  case2_root="$installer_smoke_root/case2-conflicting-table-assignment"
  case2_vault="$case2_root/vault"
  case2_yazi="$case2_root/yazi"
  case2_cache="$case2_root/cache"
  case2_backup="$case2_root/backups"
  mkdir -p "$case2_vault/.obsidian" "$case2_yazi"
  printf '[]\n' > "$case2_vault/.obsidian/community-plugins.json"
  cat > "$case2_yazi/yazi.toml" <<'EOF'
[plugin]
prepend_previewers = [
  { url = "*.txt", run = "noop-preview" },
]
EOF
  cat > "$case2_yazi/keymap.toml" <<'EOF'
[mgr]
prepend_keymap = [
  { on = "x", run = "noop", desc = "existing map" },
]
EOF

  set +e
  bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case2_vault" \
    --yazi-config "$case2_yazi" \
    --cache "$case2_cache" \
    --backup-dir "$case2_backup" \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install >/dev/null
  case2_rc="$?"
  set -e
  if [[ "$case2_rc" -eq 0 ]]; then
    die "installer smoke test failed: expected non-zero on conflicting table-scoped assignments"
  fi

  "$python_cmd" - "$case2_yazi/yazi.toml" "$case2_yazi/keymap.toml" <<'PY'
import pathlib
import sys
try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore

yazi_doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
keymap_doc = tomllib.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
if "plugin" not in yazi_doc or "prepend_previewers" not in (yazi_doc.get("plugin") or {}):
    raise SystemExit("installer conflict smoke test failed: yazi.toml lost plugin.prepend_previewers assignment")
if "mgr" not in keymap_doc or "prepend_keymap" not in (keymap_doc.get("mgr") or {}):
    raise SystemExit("installer conflict smoke test failed: keymap.toml lost mgr.prepend_keymap assignment")
PY

  # Case 3: conflicting dotted assignments should fail safely.
  case3_root="$installer_smoke_root/case3-conflicting-dotted-assignment"
  case3_vault="$case3_root/vault"
  case3_yazi="$case3_root/yazi"
  case3_cache="$case3_root/cache"
  case3_backup="$case3_root/backups"
  mkdir -p "$case3_vault/.obsidian" "$case3_yazi"
  printf '[]\n' > "$case3_vault/.obsidian/community-plugins.json"
  cat > "$case3_yazi/yazi.toml" <<'EOF'
plugin.prepend_previewers = [
  { url = "*.txt", run = "noop-preview" },
]
EOF
  cat > "$case3_yazi/keymap.toml" <<'EOF'
mgr.prepend_keymap = [
  { on = "x", run = "noop", desc = "existing map" },
]
EOF
  set +e
  bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case3_vault" \
    --yazi-config "$case3_yazi" \
    --cache "$case3_cache" \
    --backup-dir "$case3_backup" \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install >/dev/null
  case3_rc="$?"
  set -e
  if [[ "$case3_rc" -eq 0 ]]; then
    die "installer smoke test failed: expected non-zero on conflicting dotted assignments"
  fi

  "$python_cmd" - "$case3_yazi/yazi.toml" "$case3_yazi/keymap.toml" <<'PY'
import pathlib
import sys
try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore

yazi_doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
keymap_doc = tomllib.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
if "plugin" not in yazi_doc or "prepend_previewers" not in (yazi_doc.get("plugin") or {}):
    raise SystemExit("installer conflict smoke test failed: yazi.toml lost plugin.prepend_previewers assignment")
if "mgr" not in keymap_doc or "prepend_keymap" not in (keymap_doc.get("mgr") or {}):
    raise SystemExit("installer conflict smoke test failed: keymap.toml lost mgr.prepend_keymap assignment")
PY

  # Case 4: empty configs should receive managed previewer/keymap blocks.
  case4_root="$installer_smoke_root/case4-empty-config"
  case4_vault="$case4_root/vault"
  case4_yazi="$case4_root/yazi"
  case4_cache="$case4_root/cache"
  case4_backup="$case4_root/backups"
  mkdir -p "$case4_vault/.obsidian" "$case4_yazi"
  printf '[]\n' > "$case4_vault/.obsidian/community-plugins.json"
  : > "$case4_yazi/yazi.toml"
  : > "$case4_yazi/keymap.toml"
  bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case4_vault" \
    --yazi-config "$case4_yazi" \
    --cache "$case4_cache" \
    --backup-dir "$case4_backup" \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install >/dev/null

"$python_cmd" - "$case4_cache" "$case4_yazi/plugins" <<'PY'
import pathlib
import sys

cache_root = pathlib.Path(sys.argv[1]).resolve()
plugins_root = pathlib.Path(sys.argv[2]).resolve()
queue_dir = cache_root / "requests" / "queue"
if not queue_dir.is_dir():
    raise SystemExit(f"installer smoke test failed: missing cache queue dir ({queue_dir})")

expected = f'OBSIDIAN_YAZI_CACHE", "{cache_root}"'
target = plugins_root / "obsidian-common.yazi" / "main.lua"
text = target.read_text(encoding="utf-8")
if expected not in text:
    raise SystemExit(f"installer smoke test failed: cache fallback not patched in {target}")
PY

"$python_cmd" - "$case4_vault/.obsidian/plugins/yazi-exporter/data.json" "$case4_cache" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
cache_dir = pathlib.Path(str(payload.get("cacheDir", ""))).resolve()
expected = pathlib.Path(sys.argv[2]).resolve()
if cache_dir != expected:
    raise SystemExit(
        f"installer smoke test failed: plugin data.json cacheDir mismatch ({cache_dir!s} != {expected!s})"
    )
PY

  "$python_cmd" - "$case4_yazi/yazi.toml" "$case4_yazi/keymap.toml" <<'PY'
import pathlib
import sys
try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore

yazi_doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
keymap_doc = tomllib.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))

previewers = ((yazi_doc.get("plugin") or {}).get("prepend_previewers") or [])
if not any(
    isinstance(item, dict) and item.get("url") == "*.md" and item.get("run") == "obsidian-preview"
    for item in previewers
):
    raise SystemExit("installer smoke test failed: missing obsidian previewer mapping")

keymaps = ((keymap_doc.get("mgr") or {}).get("prepend_keymap") or [])
required_runs = {
    "plugin obsidian-refresh",
    "plugin obsidian-nav -- next",
    "plugin obsidian-nav -- prev",
    "plugin obsidian-toggle",
    "plugin obsidian-tune -- zoom-in",
}
actual_runs = {
    item.get("run")
    for item in keymaps
    if isinstance(item, dict) and isinstance(item.get("run"), str)
}
missing = sorted(required_runs - actual_runs)
if missing:
    raise SystemExit(f"installer smoke test failed: missing keymap runs: {', '.join(missing)}")
PY

  # Case 5: rerun on already-managed config should remain valid.
  bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case4_vault" \
    --yazi-config "$case4_yazi" \
    --cache "$case4_cache" \
    --backup-dir "$case4_backup" \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install >/dev/null

  "$python_cmd" - "$case4_yazi/yazi.toml" "$case4_yazi/keymap.toml" <<'PY'
import pathlib
import sys
try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore

for target in sys.argv[1:]:
    tomllib.loads(pathlib.Path(target).read_text(encoding="utf-8"))
PY

  # Case 6: invalid community-plugins.json should fail before any installs are applied.
  case6_root="$installer_smoke_root/case6-invalid-community-plugins-json"
  case6_vault="$case6_root/vault"
  case6_yazi="$case6_root/yazi"
  case6_cache="$case6_root/cache"
  case6_backup="$case6_root/backups"
  mkdir -p "$case6_vault/.obsidian" "$case6_yazi"
  printf 'not-json\n' > "$case6_vault/.obsidian/community-plugins.json"
  : > "$case6_yazi/yazi.toml"
  : > "$case6_yazi/keymap.toml"
  set +e
  bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case6_vault" \
    --yazi-config "$case6_yazi" \
    --cache "$case6_cache" \
    --backup-dir "$case6_backup" \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install >/dev/null
  case6_rc="$?"
  set -e
  if [[ "$case6_rc" -eq 0 ]]; then
    die "installer smoke test failed: expected non-zero on invalid community-plugins.json"
  fi
  if [[ -d "$case6_vault/.obsidian/plugins/yazi-exporter" ]]; then
    die "installer smoke test failed: plugin dir was created despite invalid community-plugins.json"
  fi
  if [[ -d "$case6_yazi/plugins/obsidian-preview.yazi" ]]; then
    die "installer smoke test failed: yazi plugin copy happened despite invalid community-plugins.json"
  fi

  # Case 7: yazi-config path that resolves to root should fail before any install mutations.
  case7_root="$installer_smoke_root/case7-yazi-config-root-alias"
  case7_vault="$case7_root/vault"
  case7_cache="$case7_root/cache"
  case7_backup="$case7_root/backups"
  mkdir -p "$case7_vault/.obsidian"
  printf '[]\n' > "$case7_vault/.obsidian/community-plugins.json"
  set +e
  bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case7_vault" \
    --yazi-config "/tmp/.." \
    --cache "$case7_cache" \
    --backup-dir "$case7_backup" \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install >/dev/null
  case7_rc="$?"
  set -e
  if [[ "$case7_rc" -eq 0 ]]; then
    die "installer smoke test failed: expected root-alias yazi config path to fail"
  fi
  if [[ -d "$case7_vault/.obsidian/plugins/yazi-exporter" ]]; then
    die "installer smoke test failed: plugin dir was created despite root-alias yazi config failure"
  fi

  # Case 7b: backup-dir path that resolves to root should fail before any install mutations.
  case7b_root="$installer_smoke_root/case7b-backup-dir-root-alias"
  case7b_vault="$case7b_root/vault"
  case7b_yazi="$case7b_root/yazi"
  case7b_cache="$case7b_root/cache"
  mkdir -p "$case7b_vault/.obsidian" "$case7b_yazi"
  printf '[]\n' > "$case7b_vault/.obsidian/community-plugins.json"
  : > "$case7b_yazi/yazi.toml"
  : > "$case7b_yazi/keymap.toml"
  set +e
  bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case7b_vault" \
    --yazi-config "$case7b_yazi" \
    --cache "$case7b_cache" \
    --backup-dir "/tmp/.." \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install >/dev/null
  case7b_rc="$?"
  set -e
  if [[ "$case7b_rc" -eq 0 ]]; then
    die "installer smoke test failed: expected root-alias backup dir path to fail"
  fi
  if [[ -d "$case7b_vault/.obsidian/plugins/yazi-exporter" ]]; then
    die "installer smoke test failed: plugin dir was created despite root-alias backup dir failure"
  fi
  if [[ -d "$case7b_yazi/plugins/obsidian-preview.yazi" ]]; then
    die "installer smoke test failed: yazi plugin copy happened despite root-alias backup dir failure"
  fi
  if grep -q 'obsidian-yazi-render:previewer:start' "$case7b_yazi/yazi.toml"; then
    die "installer smoke test failed: yazi.toml changed despite root-alias backup dir failure"
  fi
  if grep -q 'obsidian-yazi-render:custom-keys:start' "$case7b_yazi/keymap.toml"; then
    die "installer smoke test failed: keymap.toml changed despite root-alias backup dir failure"
  fi

  # Case 8: forced source-build failure should happen before any install mutations.
  case8_root="$installer_smoke_root/case8-source-build-preflight"
  case8_vault="$case8_root/vault"
  case8_yazi="$case8_root/yazi"
  case8_cache="$case8_root/cache"
  case8_backup="$case8_root/backups"
  case8_shims="$case8_root/shims"
  mkdir -p "$case8_vault/.obsidian" "$case8_yazi" "$case8_shims"
  printf '[]\n' > "$case8_vault/.obsidian/community-plugins.json"
  : > "$case8_yazi/yazi.toml"
  : > "$case8_yazi/keymap.toml"
  cat > "$case8_shims/npm" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$case8_shims/npm"
  set +e
  PATH="$case8_shims:$PATH" bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case8_vault" \
    --yazi-config "$case8_yazi" \
    --cache "$case8_cache" \
    --backup-dir "$case8_backup" \
    --force-build >/dev/null
  case8_rc="$?"
  set -e
  if [[ "$case8_rc" -eq 0 ]]; then
    die "installer smoke test failed: expected source-build preflight failure"
  fi
  if [[ -d "$case8_vault/.obsidian/plugins/yazi-exporter" ]]; then
    die "installer smoke test failed: plugin dir was created despite source-build preflight failure"
  fi
  if [[ -d "$case8_yazi/plugins/obsidian-preview.yazi" ]]; then
    die "installer smoke test failed: yazi plugin copy happened despite source-build preflight failure"
  fi
  if grep -q 'obsidian-yazi-render:previewer:start' "$case8_yazi/yazi.toml"; then
    die "installer smoke test failed: yazi.toml changed despite source-build preflight failure"
  fi
  if grep -q 'obsidian-yazi-render:custom-keys:start' "$case8_yazi/keymap.toml"; then
    die "installer smoke test failed: keymap.toml changed despite source-build preflight failure"
  fi

  # Case 9 (non-Darwin): --install-launchd should fail before any install mutations.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    case9_root="$installer_smoke_root/case9-install-launchd-non-darwin"
    case9_vault="$case9_root/vault"
    case9_yazi="$case9_root/yazi"
    case9_cache="$case9_root/cache"
    case9_backup="$case9_root/backups"
    mkdir -p "$case9_vault/.obsidian" "$case9_yazi"
    printf '[]\n' > "$case9_vault/.obsidian/community-plugins.json"
    : > "$case9_yazi/yazi.toml"
    : > "$case9_yazi/keymap.toml"
    set +e
    bash "$PACK_ROOT/scripts/install.sh" \
      --vault "$case9_vault" \
      --yazi-config "$case9_yazi" \
      --cache "$case9_cache" \
      --backup-dir "$case9_backup" \
      --prebuilt-sha256 "$trusted_prebuilt_sum" \
      --skip-npm-install \
      --install-launchd >/dev/null
    case9_rc="$?"
    set -e
    if [[ "$case9_rc" -eq 0 ]]; then
      die "installer smoke test failed: expected --install-launchd to fail on non-Darwin"
    fi
    if [[ -d "$case9_vault/.obsidian/plugins/yazi-exporter" ]]; then
      die "installer smoke test failed: plugin dir was created despite non-Darwin launchd preflight failure"
    fi
    if [[ -d "$case9_yazi/plugins/obsidian-preview.yazi" ]]; then
      die "installer smoke test failed: yazi plugin copy happened despite non-Darwin launchd preflight failure"
    fi
    if grep -q 'obsidian-yazi-render:previewer:start' "$case9_yazi/yazi.toml"; then
      die "installer smoke test failed: yazi.toml changed despite non-Darwin launchd preflight failure"
    fi
    if grep -q 'obsidian-yazi-render:custom-keys:start' "$case9_yazi/keymap.toml"; then
      die "installer smoke test failed: keymap.toml changed despite non-Darwin launchd preflight failure"
    fi
  fi

  # Case 10: symlinked yazi plugin destination must fail without writing outside.
  case10_root="$installer_smoke_root/case10-yazi-plugin-symlink-escape"
  case10_vault="$case10_root/vault"
  case10_yazi="$case10_root/yazi"
  case10_cache="$case10_root/cache"
  case10_backup="$case10_root/backups"
  case10_outside="$case10_root/outside-preview"
  mkdir -p "$case10_vault/.obsidian" "$case10_yazi/plugins" "$case10_outside"
  printf '[]\n' > "$case10_vault/.obsidian/community-plugins.json"
  : > "$case10_yazi/yazi.toml"
  : > "$case10_yazi/keymap.toml"
  ln -s "$case10_outside" "$case10_yazi/plugins/obsidian-preview.yazi"
  set +e
  bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case10_vault" \
    --yazi-config "$case10_yazi" \
    --cache "$case10_cache" \
    --backup-dir "$case10_backup" \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install >/dev/null
  case10_rc="$?"
  set -e
  if [[ "$case10_rc" -eq 0 ]]; then
    die "installer smoke test failed: expected non-zero for symlinked yazi plugin destination"
  fi
  if [[ -d "$case10_vault/.obsidian/plugins/yazi-exporter" ]]; then
    die "installer smoke test failed: vault plugin dir was created despite symlinked yazi destination"
  fi
  if [[ -n "$(find "$case10_outside" -mindepth 1 -print -quit)" ]]; then
    die "installer smoke test failed: wrote files outside yazi config root via symlink destination"
  fi

  # Case 11: symlinked vault plugin destination must fail without writing outside.
  case11_root="$installer_smoke_root/case11-vault-plugin-symlink-escape"
  case11_vault="$case11_root/vault"
  case11_yazi="$case11_root/yazi"
  case11_cache="$case11_root/cache"
  case11_backup="$case11_root/backups"
  case11_outside="$case11_root/outside-vault-plugin"
  mkdir -p "$case11_vault/.obsidian/plugins" "$case11_yazi" "$case11_outside"
  printf '[]\n' > "$case11_vault/.obsidian/community-plugins.json"
  : > "$case11_yazi/yazi.toml"
  : > "$case11_yazi/keymap.toml"
  ln -s "$case11_outside" "$case11_vault/.obsidian/plugins/yazi-exporter"
  set +e
  bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case11_vault" \
    --yazi-config "$case11_yazi" \
    --cache "$case11_cache" \
    --backup-dir "$case11_backup" \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install >/dev/null
  case11_rc="$?"
  set -e
  if [[ "$case11_rc" -eq 0 ]]; then
    die "installer smoke test failed: expected non-zero for symlinked vault plugin destination"
  fi
  if [[ -d "$case11_yazi/plugins/obsidian-preview.yazi" ]]; then
    die "installer smoke test failed: yazi plugin copy happened despite symlinked vault destination"
  fi
  if [[ -n "$(find "$case11_outside" -mindepth 1 -print -quit)" ]]; then
    die "installer smoke test failed: wrote files outside vault root via symlink destination"
  fi

  # Case 12: launchd setup failure should keep core install and return success.
  case12_root="$installer_smoke_root/case12-launchd-warning-only"
  case12_vault="$case12_root/vault"
  case12_yazi="$case12_root/yazi"
  case12_cache="$case12_root/cache"
  case12_backup="$case12_root/backups"
  case12_shims="$case12_root/shims"
  case12_home="$case12_root/home"
  mkdir -p "$case12_vault/.obsidian" "$case12_yazi" "$case12_shims" "$case12_home"
  printf '[]\n' > "$case12_vault/.obsidian/community-plugins.json"
  : > "$case12_yazi/yazi.toml"
  : > "$case12_yazi/keymap.toml"
  cat > "$case12_shims/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
  cat > "$case12_shims/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  bootstrap)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
  cat > "$case12_shims/plutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-lint" ]]; then
  [[ -f "${2:-}" ]] || exit 1
  exit 0
fi
exit 0
EOF
  chmod +x "$case12_shims/uname" "$case12_shims/launchctl" "$case12_shims/plutil"
  set +e
  HOME="$case12_home" PATH="$case12_shims:$PATH" bash "$PACK_ROOT/scripts/install.sh" \
    --vault "$case12_vault" \
    --yazi-config "$case12_yazi" \
    --cache "$case12_cache" \
    --backup-dir "$case12_backup" \
    --prebuilt-sha256 "$trusted_prebuilt_sum" \
    --skip-npm-install \
    --install-launchd >/dev/null
  case12_rc="$?"
  set -e
  if [[ "$case12_rc" -ne 0 ]]; then
    die "installer smoke test failed: expected success when launchd optional step fails"
  fi
  if [[ ! -d "$case12_yazi/plugins/obsidian-preview.yazi" ]]; then
    die "installer smoke test failed: core yazi install missing after launchd failure"
  fi
  if [[ ! -f "$case12_vault/.obsidian/plugins/yazi-exporter/main.js" ]]; then
    die "installer smoke test failed: core vault plugin install missing after launchd failure"
  fi

  # Case 13: doctor should not fail when optional Obsidian CLI is missing.
  doctor_root="$installer_smoke_root/case13-doctor-optional-cli"
  doctor_vault="$doctor_root/vault"
  doctor_yazi="$doctor_root/yazi"
  doctor_shims="$doctor_root/shims"
  mkdir -p "$doctor_vault/.obsidian" "$doctor_yazi" "$doctor_shims"
  printf '[]\n' > "$doctor_vault/.obsidian/community-plugins.json"
  cp "$PACK_ROOT/yazi/yazi.toml.snippet" "$doctor_yazi/yazi.toml"
  cp "$PACK_ROOT/yazi/keymap.toml.snippet" "$doctor_yazi/keymap.toml"
  cat > "$doctor_shims/yazi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$doctor_shims/yazi"

  doctor_path="$PATH"
  if obsidian_path="$(command -v obsidian 2>/dev/null || true)"; then
    if [[ -n "${obsidian_path:-}" ]]; then
      doctor_path="$(path_remove_dir "$doctor_path" "$(dirname "$obsidian_path")")"
    fi
  fi
  if obsidian_com_path="$(command -v Obsidian.com 2>/dev/null || true)"; then
    if [[ -n "${obsidian_com_path:-}" ]]; then
      doctor_path="$(path_remove_dir "$doctor_path" "$(dirname "$obsidian_com_path")")"
    fi
  fi
  doctor_path="$doctor_shims:$doctor_path"

  PATH="$doctor_path" bash "$PACK_ROOT/scripts/doctor.sh" \
    --vault "$doctor_vault" \
    --yazi-config "$doctor_yazi" >/dev/null

  # Case 14 (macOS): install-launchd first install + rerun update + rollback restore.
  if [[ "$(uname -s)" == "Darwin" ]]; then
    case14_root="$installer_smoke_root/case14-launchd-rerun-rollback"
    case14_launch_agents="$case14_root/LaunchAgents"
    case14_logs="$case14_root/logs"
    case14_backups="$case14_root/backups"
    case14_shims="$case14_root/shims"
    case14_launchctl_log="$case14_root/launchctl.log"
    case14_plist="$case14_launch_agents/com.obsidian-yazi-cache-cleanup.smoke.plist"
    mkdir -p "$case14_launch_agents" "$case14_logs" "$case14_backups" "$case14_shims"

    cat > "$case14_shims/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file="${MOCK_LAUNCHCTL_LOG:-}"
if [[ -n "$log_file" ]]; then
  printf '%s\n' "$*" >> "$log_file"
fi
cmd="${1:-}"
case "$cmd" in
  bootstrap)
    [[ "${MOCK_LAUNCHCTL_FAIL_BOOTSTRAP:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  enable)
    [[ "${MOCK_LAUNCHCTL_FAIL_ENABLE:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  bootout|print)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
    chmod +x "$case14_shims/launchctl"

    cat > "$case14_shims/plutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-lint" ]]; then
  [[ -f "${2:-}" ]] || exit 1
  exit 0
fi
exit 0
EOF
    chmod +x "$case14_shims/plutil"

    case14_path="$case14_shims:$PATH"

    # Path traversal in LaunchAgents should be rejected unless explicitly allowed.
    case14_home="$case14_root/home"
    mkdir -p "$case14_home/Library/LaunchAgents"
    set +e
    HOME="$case14_home" \
    PATH="$case14_path" \
    OBSIDIAN_YAZI_ALLOW_CUSTOM_PLIST_DEST=0 \
    OBSIDIAN_YAZI_PLIST_DEST="$case14_home/Library/LaunchAgents/../../escape/bad.plist" \
    OBSIDIAN_YAZI_LAUNCHD_LABEL="com.obsidian-yazi-cache-cleanup.smoke" \
    OBSIDIAN_YAZI_CLEANUP_HOUR=4 \
    OBSIDIAN_YAZI_CLEANUP_MINUTE=10 \
    bash "$PACK_ROOT/scripts/install-launchd.sh" >/dev/null 2>&1
    case14_traversal_rc="$?"
    set -e
    if [[ "$case14_traversal_rc" -eq 0 ]]; then
      die "launchd smoke failed: path traversal plist destination was not rejected"
    fi

    # First install
    PATH="$case14_path" \
    MOCK_LAUNCHCTL_LOG="$case14_launchctl_log" \
    OBSIDIAN_YAZI_ALLOW_CUSTOM_PLIST_DEST=1 \
    OBSIDIAN_YAZI_PLIST_DEST="$case14_plist" \
    OBSIDIAN_YAZI_BACKUP_DIR="$case14_backups" \
    OBSIDIAN_YAZI_CLEANUP_LOG="$case14_logs/cleanup.log" \
    OBSIDIAN_YAZI_CLEANUP_ERR_LOG="$case14_logs/cleanup.err.log" \
    OBSIDIAN_YAZI_LAUNCHD_LABEL="com.obsidian-yazi-cache-cleanup.smoke" \
    OBSIDIAN_YAZI_CLEANUP_HOUR=4 \
    OBSIDIAN_YAZI_CLEANUP_MINUTE=10 \
    bash "$PACK_ROOT/scripts/install-launchd.sh" >/dev/null

    [[ -f "$case14_plist" ]] || die "launchd smoke failed: plist was not created on first install"

    # Rerun update should succeed and change schedule.
    PATH="$case14_path" \
    MOCK_LAUNCHCTL_LOG="$case14_launchctl_log" \
    OBSIDIAN_YAZI_ALLOW_CUSTOM_PLIST_DEST=1 \
    OBSIDIAN_YAZI_PLIST_DEST="$case14_plist" \
    OBSIDIAN_YAZI_BACKUP_DIR="$case14_backups" \
    OBSIDIAN_YAZI_CLEANUP_LOG="$case14_logs/cleanup.log" \
    OBSIDIAN_YAZI_CLEANUP_ERR_LOG="$case14_logs/cleanup.err.log" \
    OBSIDIAN_YAZI_LAUNCHD_LABEL="com.obsidian-yazi-cache-cleanup.smoke" \
    OBSIDIAN_YAZI_CLEANUP_HOUR=5 \
    OBSIDIAN_YAZI_CLEANUP_MINUTE=20 \
    bash "$PACK_ROOT/scripts/install-launchd.sh" >/dev/null

    case14_expected_hash="$(sha256_file "$case14_plist" || true)"
    [[ -n "$case14_expected_hash" ]] || die "launchd smoke failed: unable to hash updated plist"

    # Forced enable failure should trigger rollback to the previous plist.
    set +e
    PATH="$case14_path" \
    MOCK_LAUNCHCTL_LOG="$case14_launchctl_log" \
    MOCK_LAUNCHCTL_FAIL_ENABLE=1 \
    OBSIDIAN_YAZI_ALLOW_CUSTOM_PLIST_DEST=1 \
    OBSIDIAN_YAZI_PLIST_DEST="$case14_plist" \
    OBSIDIAN_YAZI_BACKUP_DIR="$case14_backups" \
    OBSIDIAN_YAZI_CLEANUP_LOG="$case14_logs/cleanup.log" \
    OBSIDIAN_YAZI_CLEANUP_ERR_LOG="$case14_logs/cleanup.err.log" \
    OBSIDIAN_YAZI_LAUNCHD_LABEL="com.obsidian-yazi-cache-cleanup.smoke" \
    OBSIDIAN_YAZI_CLEANUP_HOUR=6 \
    OBSIDIAN_YAZI_CLEANUP_MINUTE=30 \
    bash "$PACK_ROOT/scripts/install-launchd.sh" >/dev/null
    case14_fail_rc="$?"
    set -e
    if [[ "$case14_fail_rc" -eq 0 ]]; then
      die "launchd smoke failed: expected install-launchd.sh to fail on forced enable error"
    fi

    case14_after_hash="$(sha256_file "$case14_plist" || true)"
    if [[ "$case14_after_hash" != "$case14_expected_hash" ]]; then
      die "launchd smoke failed: plist was not restored after forced failure"
    fi

    grep -q 'bootstrap' "$case14_launchctl_log" || die "launchd smoke failed: bootstrap was not invoked"
    grep -q 'enable' "$case14_launchctl_log" || die "launchd smoke failed: enable was not invoked"
  fi

  cleanup_installer_smoke
  trap - EXIT
  ok "Installer config-merge smoke tests succeeded"
fi

info "Checking release-noise files"
noise_pathspecs=(
  'AGENTS.md'
  ':(glob)**/AGENTS.md'
  'bridge*.md'
  ':(glob)**/bridge*.md'
  'bridge/**'
  ':(glob)**/bridge/**'
  'bridge-*/**'
  ':(glob)**/bridge-*/**'
  'bridge_*/**'
  ':(glob)**/bridge_*/**'
  'ssh/**'
  ':(glob)**/ssh/**'
  'ssh*.md'
  ':(glob)**/ssh*.md'
  'ssh-*/**'
  ':(glob)**/ssh-*/**'
  'ssh_*/**'
  ':(glob)**/ssh_*/**'
  '.ssh/**'
  ':(glob)**/.ssh/**'
  '*.pem'
  ':(glob)**/*.pem'
  '*.ppk'
  ':(glob)**/*.ppk'
  'id_rsa*'
  ':(glob)**/id_rsa*'
  'id_ed25519*'
  ':(glob)**/id_ed25519*'
  'skill/**'
  ':(glob)**/skill/**'
  'skill*.md'
  ':(glob)**/skill*.md'
  'skills/**'
  ':(glob)**/skills/**'
  'release-audit-*/**'
  ':(glob)**/release-audit-*/**'
  'AUDIT_STATUS.md'
  ':(glob)**/AUDIT_STATUS.md'
  'INVENTORY.txt'
  ':(glob)**/INVENTORY.txt'
)

collect_noise() {
  local mode="$1"
  shift || true
  case "$mode" in
    tracked)
      git -C "$PACK_ROOT" ls-files -- "${noise_pathspecs[@]}" || true
      ;;
    untracked)
      git -C "$PACK_ROOT" ls-files --others --exclude-standard -- "${noise_pathspecs[@]}" || true
      ;;
    ignored)
      git -C "$PACK_ROOT" ls-files --others --ignored --exclude-standard -- "${noise_pathspecs[@]}" || true
      ;;
    *)
      return 1
      ;;
  esac
}

tracked_noise="$(collect_noise tracked)"
if [[ -n "$tracked_noise" ]]; then
  if [[ "$STRICT_NOISE" == "1" ]]; then
    die "Tracked local/noise files are present. Remove them before release."
  fi
  warn "Tracked local/noise files detected (strict noise check is disabled):"
  printf '%s\n' "$tracked_noise" >&2
else
  ok "No tracked local/noise files detected"
fi

untracked_noise="$(collect_noise untracked)"
if [[ -n "$untracked_noise" ]]; then
  if [[ "$STRICT_NOISE" == "1" ]]; then
    die "Untracked local/noise files are present. Remove them before release."
  fi
  warn "Untracked local/noise files detected (strict noise check is disabled):"
  printf '%s\n' "$untracked_noise" >&2
else
  ok "No untracked local/noise files detected"
fi

# Packaging allowlist includes broad trees under scripts/, yazi/, obsidian-plugin/.
# Restrict ignored-file gate to those trees to catch archive-relevant bypasses.
ignored_noise="$(collect_noise ignored | grep -E '^(scripts|yazi|obsidian-plugin)/' || true)"
if [[ -n "$ignored_noise" ]]; then
  if [[ "$STRICT_NOISE" == "1" ]]; then
    die "Ignored local/noise files are present. Remove them before release."
  fi
  warn "Ignored local/noise files detected (strict noise check is disabled):"
  printf '%s\n' "$ignored_noise" >&2
else
  ok "No ignored local/noise files detected"
fi

info "Checking allowlisted subtree contamination"
allowlist_subtree_specs=(
  'scripts'
  'yazi'
  'obsidian-plugin/yazi-exporter/src'
  'obsidian-plugin/yazi-exporter/test'
  'obsidian-plugin/yazi-exporter/prebuilt'
)

allowlist_untracked="$(git -C "$PACK_ROOT" ls-files --others --exclude-standard -- "${allowlist_subtree_specs[@]}" || true)"
if [[ -n "$allowlist_untracked" ]]; then
  die "Untracked files detected under package allowlisted trees:
$allowlist_untracked"
fi

allowlist_ignored="$(git -C "$PACK_ROOT" ls-files --others --ignored --exclude-standard -- "${allowlist_subtree_specs[@]}" || true)"
if [[ -n "$allowlist_ignored" ]]; then
  die "Ignored files detected under package allowlisted trees:
$allowlist_ignored"
fi
ok "Allowlisted subtree contamination check passed"

ok "Release checks completed"
