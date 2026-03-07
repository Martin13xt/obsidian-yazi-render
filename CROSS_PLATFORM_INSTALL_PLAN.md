# Cross Platform Install Plan

このドキュメントは `obsidian-yazi-render` の OS 別導入方法と、その手順を採用する理由をまとめたものです。

## サポート状況

- macOS: 公式サポート（自動インストーラあり）
- Linux: 公式サポート（手動導入、POSIX環境）
- Windows: 公式サポート（手動導入、POSIX互換レイヤー前提）

---

## macOS 導入手順（推奨）

### 手順

```bash
cd /path/to/obsidian-yazi-render
./scripts/install-easy.sh --auto-brew --yes --vault "/path/to/vault"
```

任意（TTLクリーンアップを launchd 再設定）:

```bash
./scripts/install-launchd.sh
```

確認:

```bash
./scripts/doctor.sh --vault "/path/to/vault"
```

### この手順を使う理由

- 依存導入（brew）+ 設定反映を一括で実行できるため（`--prebuilt-sha256` 指定時のみ trusted prebuilt を検証利用。未指定時はソースビルドへフォールバック）
- macOS では `launchd` が標準スケジューラで、日次 cleanup を安定運用しやすいため
- 現在の CI / 実運用実績が最も多く、トラブルシュート情報が揃っているため

---

## Linux 導入手順（手動）

### 1) 依存導入

Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y yazi jq curl rsync ripgrep
```

Fedora:

```bash
sudo dnf install -y yazi jq curl rsync ripgrep
```

Arch:

```bash
sudo pacman -S --noconfirm yazi jq curl rsync ripgrep
```

### 2) yazi プラグイン配置

```bash
YAZI_DIR="${YAZI_CONFIG_DIR:-${YAZI_CONFIG_HOME:-$HOME/.config/yazi}}"
mkdir -p "$YAZI_DIR/plugins"
cp -R yazi/plugins/obsidian-preview.yazi "$YAZI_DIR/plugins/"
cp -R yazi/plugins/obsidian-toggle.yazi  "$YAZI_DIR/plugins/"
cp -R yazi/plugins/obsidian-nav.yazi     "$YAZI_DIR/plugins/"
cp -R yazi/plugins/obsidian-refresh.yazi "$YAZI_DIR/plugins/"
cp -R yazi/plugins/obsidian-tune.yazi    "$YAZI_DIR/plugins/"
```

### 2.5) yazi snippet 適用（manual 導線で必須）

```bash
YAZI_DIR="${YAZI_CONFIG_DIR:-${YAZI_CONFIG_HOME:-$HOME/.config/yazi}}"
touch "$YAZI_DIR/yazi.toml" "$YAZI_DIR/keymap.toml"

if ! rg -q 'obsidian-yazi-render:previewer:start' "$YAZI_DIR/yazi.toml"; then
  printf '\n%s\n' "$(cat yazi/yazi.toml.snippet)" >> "$YAZI_DIR/yazi.toml"
fi
if ! rg -q 'obsidian-yazi-render:custom-keys:start' "$YAZI_DIR/keymap.toml"; then
  printf '\n%s\n' "$(cat yazi/keymap.toml.snippet)" >> "$YAZI_DIR/keymap.toml"
fi
```

これで `.md` previewer 登録と `J/K/U/R` などの keymap が有効化されます。

`yazi/yazi.toml.snippet` と `yazi/keymap.toml.snippet` は managed block 方式です。  
既存設定へ追記する場合でも、同名配列代入（例: `plugin.prepend_previewers = [...]` / `mgr.prepend_keymap = [...]` または `[plugin] prepend_previewers = [...]` / `[mgr] prepend_keymap = [...]`）を重複定義しないでください。

衝突した場合（install が中断した場合）の手動復旧:

```bash
YAZI_DIR="${YAZI_CONFIG_DIR:-${YAZI_CONFIG_HOME:-$HOME/.config/yazi}}"
echo "Use yazi config dir: $YAZI_DIR"

# 1) 既存定義の確認（重複がないか）
rg -n 'prepend_previewers|prepend_keymap|^\[plugin\]|^\[mgr\]' "$YAZI_DIR"/yazi.toml "$YAZI_DIR"/keymap.toml

# 2) snippet を参照しながら既存配列へ統合
sed -n '1,200p' yazi/yazi.toml.snippet
sed -n '1,200p' yazi/keymap.toml.snippet
```

その後 `./scripts/install.sh --vault "/path/to/vault"` を再実行してください。

### 3) Obsidian プラグイン配置（prebuilt）

```bash
VAULT="/path/to/vault"
TRUSTED_SHA256="$(tr -d '[:space:]' < obsidian-yazi-render-<VERSION>.prebuilt-main.js.sha256)"
if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(shasum -a 256 obsidian-plugin/yazi-exporter/prebuilt/main.js | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256="$(sha256sum obsidian-plugin/yazi-exporter/prebuilt/main.js | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
  ACTUAL_SHA256="$(openssl dgst -sha256 obsidian-plugin/yazi-exporter/prebuilt/main.js | awk '{print $NF}')"
else
  echo "No SHA-256 command found (need shasum/sha256sum/openssl)" >&2
  exit 1
fi
if [ "$TRUSTED_SHA256" != "$ACTUAL_SHA256" ]; then
  echo "prebuilt checksum mismatch" >&2
  exit 1
fi
mkdir -p "$VAULT/.obsidian/plugins/yazi-exporter"
cp obsidian-plugin/yazi-exporter/prebuilt/main.js "$VAULT/.obsidian/plugins/yazi-exporter/main.js"
cp obsidian-plugin/yazi-exporter/manifest.json "$VAULT/.obsidian/plugins/yazi-exporter/manifest.json"
cp obsidian-plugin/yazi-exporter/styles.css "$VAULT/.obsidian/plugins/yazi-exporter/styles.css"
```

注意:
- `TRUSTED_SHA256` は GitHub Releases のアセット `obsidian-yazi-render-<VERSION>.prebuilt-main.js.sha256` から取得してください
- 同梱 `main.js.sha256` は信頼境界として扱わないでください

### 4) 手動導線で必要な追加設定

手動コピー方式では、yazi 側プラグインの既定 Vault は `~/obsidian` のままです。  
実運用の Vault に合わせるため、`OBSIDIAN_VAULT_ROOT` を明示してください。

```bash
export OBSIDIAN_VAULT_ROOT="/path/to/vault"
```

また、Obsidian 側で `yazi-exporter` を有効化してください（Community plugins）。

### 5) 日次 cleanup（systemd --user 例）

`~/.config/systemd/user/obsidian-yazi-cache-cleanup.service`:

```ini
[Unit]
Description=Obsidian Yazi cache cleanup

[Service]
Type=oneshot
ExecStart=/path/to/obsidian-yazi-render/scripts/cleanup-cache.sh
```

`~/.config/systemd/user/obsidian-yazi-cache-cleanup.timer`:

```ini
[Unit]
Description=Run Obsidian Yazi cache cleanup daily

[Timer]
OnCalendar=*-*-* 04:10:00
Persistent=true

[Install]
WantedBy=timers.target
```

有効化:

```bash
systemctl --user daemon-reload
systemctl --user enable --now obsidian-yazi-cache-cleanup.timer
```

### この手順を使う理由

- Linux は配布ごとにパッケージ管理が異なり、自動導入を一本化しづらいため
- 標準スケジューラとして `systemd --user timer` が最も再現性が高いため
- prebuilt 配置で Node 依存を避け、導入失敗要因を減らせるため

---

## Windows 導入手順（手動）

> [!IMPORTANT]
> 現在の yazi ランタイムプラグインは `sh` / `md5sum` / `chmod` / `mv` / `find` など POSIX コマンドを利用します。  
> Windows ネイティブのみの PATH では不足するため、MSYS2 / Git Bash / WSL などで POSIX コマンドを実行可能にしてください（yazi 実行環境の PATH から見えることが必要）。

### 1) 依存導入（PowerShell）

```powershell
winget install --id sxyazi.yazi -e
winget install --id jqlang.jq -e
```

`curl` は Windows 標準同梱を利用可能。

### 2) yazi プラグイン配置

```powershell
$YaziDir = if ($env:YAZI_CONFIG_DIR) {
  $env:YAZI_CONFIG_DIR
} elseif ($env:YAZI_CONFIG_HOME) {
  $env:YAZI_CONFIG_HOME
} else {
  Join-Path $HOME ".config\yazi"
}

$PluginsDir = Join-Path $YaziDir "plugins"
New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null
Copy-Item "yazi\plugins\obsidian-preview.yazi" $PluginsDir -Recurse -Force
Copy-Item "yazi\plugins\obsidian-toggle.yazi"  $PluginsDir -Recurse -Force
Copy-Item "yazi\plugins\obsidian-nav.yazi"     $PluginsDir -Recurse -Force
Copy-Item "yazi\plugins\obsidian-refresh.yazi" $PluginsDir -Recurse -Force
Copy-Item "yazi\plugins\obsidian-tune.yazi"    $PluginsDir -Recurse -Force
```

### 2.5) yazi snippet 適用（manual 導線で必須）

```powershell
$YaziToml = Join-Path $YaziDir "yazi.toml"
$KeymapToml = Join-Path $YaziDir "keymap.toml"
New-Item -ItemType File -Path $YaziToml -Force | Out-Null
New-Item -ItemType File -Path $KeymapToml -Force | Out-Null

if (-not (Select-String -Path $YaziToml -Pattern 'obsidian-yazi-render:previewer:start' -Quiet)) {
  Add-Content -Path $YaziToml -Value "`n$(Get-Content 'yazi\yazi.toml.snippet' -Raw)"
}
if (-not (Select-String -Path $KeymapToml -Pattern 'obsidian-yazi-render:custom-keys:start' -Quiet)) {
  Add-Content -Path $KeymapToml -Value "`n$(Get-Content 'yazi\keymap.toml.snippet' -Raw)"
}
```

これで `.md` previewer 登録と `J/K/U/R` などの keymap が有効化されます。

### 3) Obsidian プラグイン配置（prebuilt）

```powershell
$Vault = "C:\path\to\vault"
$PluginDir = Join-Path $Vault ".obsidian\plugins\yazi-exporter"
$Expected = (Get-Content ".\obsidian-yazi-render-<VERSION>.prebuilt-main.js.sha256" -Raw).Trim().ToLower()
$Actual = (Get-FileHash "obsidian-plugin\yazi-exporter\prebuilt\main.js" -Algorithm SHA256).Hash.ToLower()
if ($Expected.ToLower() -ne $Actual) { throw "prebuilt checksum mismatch" }
New-Item -ItemType Directory -Path $PluginDir -Force | Out-Null
Copy-Item "obsidian-plugin\yazi-exporter\prebuilt\main.js" (Join-Path $PluginDir "main.js") -Force
Copy-Item "obsidian-plugin\yazi-exporter\manifest.json" (Join-Path $PluginDir "manifest.json") -Force
Copy-Item "obsidian-plugin\yazi-exporter\styles.css" (Join-Path $PluginDir "styles.css") -Force
```

注意:
- `$Expected` は GitHub Releases のアセット `obsidian-yazi-render-<VERSION>.prebuilt-main.js.sha256` から取得してください
- 同梱 `main.js.sha256` は信頼境界として扱わないでください

### 4) 手動導線で必要な追加設定

PowerShell で、実運用の Vault を環境変数で明示します（手動コピー時の既定値 `~/obsidian` 回避）。

```powershell
$env:OBSIDIAN_VAULT_ROOT = "C:\path\to\vault"
```

また、Obsidian 側で `yazi-exporter` を有効化してください（Community plugins）。

### 5) 日次 cleanup（Task Scheduler）

```powershell
$Script = "C:\path\to\obsidian-yazi-render\scripts\cleanup-cache.ps1"
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Script`""
$Trigger = New-ScheduledTaskTrigger -Daily -At 4:10am
Register-ScheduledTask -TaskName "ObsidianYaziCacheCleanup" -Action $Action -Trigger $Trigger -Description "Cleanup Obsidian Yazi cache" -Force
```

注意:
- 上記コマンドは純 PowerShell だけで完結します
- 実行ポリシーが厳しい環境では `-ExecutionPolicy` の運用ルールに合わせて調整してください

### この手順を使う理由

- Windows では shell / path / scheduler が POSIX と大きく異なるため
- 現在のランタイムは POSIX コマンド群に依存するため、互換レイヤー前提で段階的に運用するため
- Task Scheduler が標準で、cron/launchd 互換を期待できないため
- prebuilt 配置で Node/npm セットアップを避け、最短導入できるため

---

## 互換性とセキュリティ方針（全OS共通）

- REST 接続先は既定で loopback のみ許可  
  非 loopback は `OBSIDIAN_REST_ALLOW_REMOTE=1` が必要
- TLS 検証は未設定時に loopback=`OFF` / 非loopback=`ON`
- `install.sh` は `--prebuilt-sha256`（外部で検証済みの trusted checksum）を要求  
  未指定/不一致時は prebuilt を使わずソースビルドへフォールバック
- キャッシュは Vault 外に保存し、TTL で cleanup
- POSIX は cache dirs `700` を維持（Windows はユーザー ACL 前提）

---

## 全OS共通の動作確認

- `.md` hover で自動生成される
- `R` toggle / `J,K` page / `U` refresh が動く
- stale 判定（TTL + `.md`更新 + renderer更新）が効く
- cleanup が日次実行される
- Obsidian 前面化が常時起きない（REST優先）
