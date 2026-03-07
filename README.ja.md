<h1 align="center">Obsidian Yazi Render</h1>

<p align="center">
  <b>ターミナルファイラー <a href="https://github.com/sxyazi/yazi">yazi</a> 上で、Obsidian ノートを Obsidian そのままの見た目で PNG プレビュー。</b>
</p>

<p align="center">
  <a href="README.md"><img alt="English" src="https://img.shields.io/badge/lang-English-blue" /></a>
  <img alt="Stage: beta" src="https://img.shields.io/badge/stage-beta-orange" />
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green" /></a>
  <img alt="yazi v26.1.22+" src="https://img.shields.io/badge/yazi-v26.1.22%2B-1f6feb" />
  <img alt="macOS / Linux / Windows" src="https://img.shields.io/badge/os-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey" />
</p>
<p align="center">
  <a href="https://github.com/codikzng/obsidian-yazi-render/stargazers"><img alt="GitHub Stars" src="https://img.shields.io/github/stars/codikzng/obsidian-yazi-render?style=social" /></a>
  <a href="https://github.com/codikzng/obsidian-yazi-render/commits/main"><img alt="Last Commit" src="https://img.shields.io/github/last-commit/codikzng/obsidian-yazi-render" /></a>
  <a href="https://github.com/codikzng/obsidian-yazi-render/issues"><img alt="Open Issues" src="https://img.shields.io/github/issues/codikzng/obsidian-yazi-render" /></a>
</p>

<p align="center"><img src="docs/demo.gif" alt="デモ — Obsidian ノートを yazi ターミナルファイラーで PNG プレビュー" width="800" /></p>

**Obsidian Yazi Render** はターミナルを Obsidian ノートビューアに変えます。[yazi](https://github.com/sxyazi/yazi) で Vault を閲覧しながら、各 Markdown ノートをピクセルパーフェクトな PNG として表示 — コールアウト、Mermaid、数式、埋め込み画像、Obsidian テーマがそのまま Kitty / Sixel グラフィクスプロトコルで描画されます。ブラウザ不要、Electron 不要、ターミナルだけで完結します。

---

## 特徴

- **Obsidian 完全準拠の描画** --- コールアウト、数式、Mermaid、埋め込み画像、テーマすべてそのまま PNG 化
- **高速キャッシュ** --- 一度レンダリングすれば Vault 外キャッシュから即座に表示。ノート更新時だけ自動再生成
- **ペインサイズ自動適応** --- ブラウザのようにペイン幅・高さに合わせて描画範囲を自動最適化
- **ページ送り** --- 長いノートは自動でページ分割。<kbd>Shift+J</kbd> / <kbd>Shift+K</kbd> でめくれる
- **表示切替** --- <kbd>Shift+R</kbd> で PNG とプレーンテキスト Markdown を即座に切り替え
- **読みやすさ調整** --- <kbd>,</kbd> <kbd>=</kbd> / <kbd>,</kbd> <kbd>-</kbd> で文字サイズを調整

---

## 動作環境

| 区分 | 要件 |
|:-----|:-----|
| **OS** | macOS（推奨）・Linux・Windows（WSL / MSYS2 等の POSIX レイヤー） |
| **yazi** | v26.1.22 以降 |
| **Obsidian** | デスクトップ版 v1.6.0 以降（起動したままにしておく） |
| **Obsidian プラグイン** | [Local REST API](https://github.com/coddingtonbear/obsidian-local-rest-api)（推奨経路で必須） |
| **Node.js** | v20.19.0 以上（ソースビルド時のみ。prebuilt 利用時は不要） |
| **CLI ツール** | `jq`、`rsync`（インストーラ）、`curl`（REST 経路のランタイム） |

---

## 仕組み

<p align="center"><img src="docs/how-it-works.png" alt="仕組み — アーキテクチャ図" width="800" /></p>

> [!TIP]
> 再生成は以下の条件で自動的に発生します:
> - ノート（.md）が更新された
> - ペインサイズが大きく変わった
> - キャッシュの TTL（既定 3 日）を超過した

---

## レンダリング経路

Obsidian にレンダリングを依頼する方法は 3 つあります。

| 経路 | 環境変数 | 既定 | 特徴 |
|:-----|:---------|:----:|:-----|
| **REST** | `OBSIDIAN_YAZI_USE_REST` | `1` | Local REST API 経由。バックグラウンドで完結。**最も安定** |
| CLI | `OBSIDIAN_YAZI_CLI_FALLBACK` | `0` | Obsidian CLI で直接実行 |
| URI | `OBSIDIAN_YAZI_URI_FALLBACK` | `0` | `obsidian://adv-uri` 経由（[Advanced URI](https://github.com/Vinzent03/obsidian-advanced-uri) プラグインが必要） |

> [!IMPORTANT]
> **REST を強く推奨します。** REST ならバックグラウンドで完結し、Obsidian がフォーカスを奪いません。CLI と URI は REST が使えない環境のためのフォールバックです。

---

## 画像表示プロトコル

画像表示は yazi がターミナルの対応プロトコルを自動検出するため、設定は不要です。

| プロトコル | 対応ターミナル例 | 備考 |
|:----------|:----------------|:-----|
| **Kitty graphics protocol** | Kitty・Ghostty・WezTerm | **推奨。** 最高品質で安定した表示 |
| Sixel | foot・mlterm・xterm (sixel build) | 広い互換性 |
| Inline Images Protocol | iTerm2・Hyper | macOS ネイティブターミナル向け |

> [!TIP]
> **Kitty graphics protocol 対応ターミナルがおすすめです。** Ghostty と WezTerm で動作確認済み。

---

## インストール

### macOS（推奨フロー）

```bash
git clone https://github.com/codikzng/obsidian-yazi-render.git
cd obsidian-yazi-render
./scripts/install-easy.sh --auto-brew --yes --vault "/path/to/your/vault"
```

> [!NOTE]
> `--auto-brew` は Homebrew で不足パッケージ（`jq`、`curl` 等）を自動インストールします。

### prebuilt 利用（Node.js 不要）

```bash
cd obsidian-yazi-render
./scripts/install.sh --vault "/path/to/your/vault" \
  --prebuilt-sha256 "<TRUSTED_SHA256_FROM_RELEASE>"
```

SHA-256 の値は GitHub Release のアセット `obsidian-yazi-render-<VERSION>.prebuilt-main.js.sha256` から取得してください。

### インストール後の確認

```bash
./scripts/doctor.sh --vault "/path/to/your/vault"
```

`doctor.sh` が環境を自動診断し、問題があれば修正方法を提示します。

### Obsidian 側の設定

1. コミュニティプラグイン **Local REST API** をインストール・有効化
2. Obsidian を起動したままにしておく

> [!WARNING]
> 生成された PNG は **Vault 外のキャッシュディレクトリ**に保存されます。機密ノートを扱う場合は、キャッシュディレクトリの権限と同期設定を確認してください。

<details>
<summary><b>既存の yazi 設定とコンフリクトした場合</b></summary>

既存の `yazi.toml` / `keymap.toml` が `plugin.prepend_previewers = [...]`（dotted）または `[plugin] prepend_previewers = [...]`（table）形式の場合、インストーラは安全のため自動マージを中断します。

**手動マージの手順:**

1. yazi 設定ディレクトリを開く（`$YAZI_CONFIG_DIR` > `$YAZI_CONFIG_HOME` > `~/.config/yazi`）
2. `yazi/yazi.toml.snippet` と `yazi/keymap.toml.snippet` のエントリを既存の配列に追加
3. `./scripts/install.sh --vault "/path/to/your/vault"` を再実行

</details>

<details>
<summary><b>Linux / Windows での手動インストール</b></summary>

- Linux: POSIX 環境であればそのまま `install.sh` が利用可能
- Windows: WSL / MSYS2 / Git Bash 等の POSIX 互換レイヤーが必要

詳細は [CROSS_PLATFORM_INSTALL_PLAN.md](CROSS_PLATFORM_INSTALL_PLAN.md) を参照してください。

変更前に何が行われるか確認したい場合:

```bash
./scripts/install.sh --vault "/path/to/your/vault" --dry-run
```

</details>

---

## 使い方

### 基本操作

`.md` ファイルにカーソルを合わせるだけです。初回はレンダリングが走り、以降はキャッシュから即表示されます。

### キーバインド

| キー | 操作 |
|:-----|:-----|
| <kbd>Shift+J</kbd> / <kbd>,</kbd> <kbd>j</kbd> | 次のページ |
| <kbd>Shift+K</kbd> / <kbd>,</kbd> <kbd>k</kbd> | 前のページ |
| <kbd>Shift+R</kbd> / <kbd>,</kbd> <kbd>p</kbd> | PNG / Markdown 表示切替 |
| <kbd>Shift+U</kbd> / <kbd>,</kbd> <kbd>u</kbd> | 現在のノートを強制再生成 |
| <kbd>,</kbd> <kbd>=</kbd> | 文字を大きく |
| <kbd>,</kbd> <kbd>-</kbd> | 文字を小さく |
| <kbd>,</kbd> <kbd>0</kbd> | ズームをリセット |

### ペインサイズへの自動適応

ターミナルのペインサイズを変更すると、描画範囲が自動で再計算されます。横長でも縦長でも、コンテンツが中央に適切なサイズで表示されます。

<details>
<summary><b>描画パラメータの微調整</b></summary>

| 環境変数 | 既定値 | 用途 |
|:---------|:------:|:-----|
| `OBSIDIAN_YAZI_PX_PER_COL` | `9` | 1 カラムあたりの描画ピクセル数 |
| `OBSIDIAN_YAZI_TERM_CELL_ASPECT` | `2.10` | ターミナルセルの縦横比（高さ/幅） |
| `OBSIDIAN_YAZI_PAGE_HEIGHT_BIAS` | `1.00` | ページ高さの補正係数 |
| `OBSIDIAN_YAZI_MIN_PANE_FILL_RATIO` | `1.00` | ペイン充填率の最小値 |
| `OBSIDIAN_YAZI_RENDER_SCALE_GHOSTTY` | `1.06` | Ghostty 向けスケール補正 |
| `OBSIDIAN_YAZI_RENDER_SCALE_WEZTERM` | `1.06` | WezTerm 向けスケール補正 |
| `OBSIDIAN_YAZI_RENDER_SCALE` | ― | 全ターミナル共通のスケール上書き |

</details>

---

## トラブルシューティング

まず `doctor.sh` を実行してください:

```bash
./scripts/doctor.sh --vault "/path/to/your/vault"
```

| 症状 | 対処 |
|:-----|:-----|
| プレビューが生成されない | Local REST API が有効か確認。`OBSIDIAN_API_KEY` を確認 |
| Obsidian が前面に来る | `OBSIDIAN_YAZI_USE_REST=1` を確認。CLI/URI フォールバックを無効に |
| 画像が古い | <kbd>Shift+U</kbd> で再生成 |
| 画像がぼやける | Yazi Exporter 設定で Pixel ratio を上げる（例: `2.0`） |
| 末尾が切れる | Yazi Exporter 設定で Max image height を `0` に |
| `http status 401` | `OBSIDIAN_API_KEY` の値を修正 |

<details>
<summary><b>その他の設定項目</b></summary>

| 環境変数 | 既定値 | 用途 |
|:---------|:------:|:-----|
| `OBSIDIAN_YAZI_CACHE` | macOS: `~/Library/Caches/obsidian-yazi`、Linux: `${XDG_CACHE_HOME:-~/.cache}/obsidian-yazi`、フォールバック: `/tmp/obsidian-yazi` | キャッシュ保存先 |
| `OBSIDIAN_API_KEY` | 自動検出 | Local REST API キー |
| `OBSIDIAN_YAZI_QUEUE_MAX_FILES` | `16` | レンダリングキュー上限 |
| `OBSIDIAN_YAZI_LAYOUT_SETTLE_SECS` | `1.0` | ペインサイズ安定待ち秒数 |
| `OBSIDIAN_VAULT_NAME` | `obsidian` | URI/CLI で使用する Vault 名 |
| `OBSIDIAN_YAZI_DEBUG_INCLUDE_PATHS` | `0` | デバッグログにパスを表示 |

`install.sh --cache ...` でキャッシュパスを yazi 側と Obsidian プラグイン設定の両方に同期できます。

</details>

---

## アンインストール

<details>
<summary><b>完全アンインストール手順</b></summary>

```bash
# 1. yazi プラグインを削除
#    yazi config dir は $YAZI_CONFIG_DIR > $YAZI_CONFIG_HOME > ~/.config/yazi の優先順
YAZI_DIR="${YAZI_CONFIG_DIR:-${YAZI_CONFIG_HOME:-$HOME/.config/yazi}}"
rm -rf "$YAZI_DIR"/plugins/obsidian-{preview,toggle,nav,refresh,tune,common}.yazi

# 2. yazi 設定ファイルから本プロジェクトのエントリを手動で削除
#    $YAZI_DIR/yazi.toml  (prepend_previewers の obsidian-preview 行)
#    $YAZI_DIR/keymap.toml (obsidian-* 関連のキーバインド)

# 3. Obsidian プラグインを削除
rm -rf "/path/to/your/vault/.obsidian/plugins/yazi-exporter"

# 4. community-plugins.json から yazi-exporter を削除
#    /path/to/your/vault/.obsidian/community-plugins.json を編集し
#    "yazi-exporter" エントリを除去してください

# 5. キャッシュを削除
rm -rf "${OBSIDIAN_YAZI_CACHE:-$HOME/Library/Caches/obsidian-yazi}"
# Linux: rm -rf "${OBSIDIAN_YAZI_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/obsidian-yazi}"

# 6. インストーラのバックアップを削除（存在する場合）
rm -rf "${OBSIDIAN_YAZI_BACKUP_DIR:-$HOME/.obsidian-yazi-render-backups}"

# 7. (macOS のみ) launchd ジョブとログを削除（install-launchd.sh を使った場合）
launchctl unload ~/Library/LaunchAgents/com.obsidian-yazi-cache-cleanup.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.obsidian-yazi-cache-cleanup.plist
rm -f ~/Library/Logs/obsidian-yazi-cache-cleanup.log
rm -f ~/Library/Logs/obsidian-yazi-cache-cleanup.err.log

# 8. /tmp のフォールバックキャッシュを削除（存在する場合）
rm -rf /tmp/obsidian-yazi
```

> [!NOTE]
> launchd 関連のカスタム環境変数（`OBSIDIAN_YAZI_LAUNCHD_LABEL`、`OBSIDIAN_YAZI_PLIST_DEST`、`OBSIDIAN_YAZI_CLEANUP_LOG`、`OBSIDIAN_YAZI_CLEANUP_ERR_LOG`）を変更していた場合は、そのパスに合わせて unload 対象と削除先を差し替えてください。

Obsidian 側で Local REST API プラグインを無効化すれば、REST 経由の通信も完全に停止します。

</details>

---

## 既知の制限

- **Obsidian を起動しておく必要がある** --- レンダリングは Obsidian 本体が行うため、起動していないとプレビューは生成されません
- **初回レンダリングには数秒かかる** --- 2 回目以降はキャッシュから即表示されます
- **対象は `.md` ファイルのみ** --- canvas やその他の形式には対応していません
- **Kitty graphics protocol 非対応ターミナルでは表示品質が低下する場合がある** --- Sixel 等でも動作しますが、Kitty protocol 対応ターミナルが推奨です
- **Vault 外のファイルはプレビューできない** --- Obsidian の Vault 内にあるノートのみが対象です
- **URI フォールバックは Advanced URI プラグインが前提** --- URI 経路は `obsidian://adv-uri` を使用するため、[Advanced URI](https://github.com/Vinzent03/obsidian-advanced-uri) プラグインが必要です

---

## 関連ドキュメント

| ドキュメント | 内容 |
|:------------|:-----|
| [TECHNICAL_DETAILS.md](TECHNICAL_DETAILS.md) | アーキテクチャと全環境変数 |
| [CROSS_PLATFORM_INSTALL_PLAN.md](CROSS_PLATFORM_INSTALL_PLAN.md) | Linux / Windows 導入手順 |
| [SECURITY.md](SECURITY.md) | セキュリティ方針 |
| [CHANGELOG.md](CHANGELOG.md) | 変更履歴 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | コントリビューションガイド |
| [README.md](README.md) | English version |

## Star History

<a href="https://star-history.com/#codikzng/obsidian-yazi-render&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=codikzng/obsidian-yazi-render&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=codikzng/obsidian-yazi-render&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=codikzng/obsidian-yazi-render&type=Date" width="600" />
  </picture>
</a>

## ライセンス

MIT License
