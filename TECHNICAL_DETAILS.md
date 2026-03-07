# Obsidian Yazi Render Pack 技術詳細

## 概要

このパッケージは、Obsidianノート（Markdown）をVault外のPNGキャッシュにレンダし、yaziで画像プレビューするための連携実装です。

構成は大きく次の2層です。

- yazi層: プレビュー制御、表示モード切替、ページ送り、キャッシュ削除
- Obsidian層: ノートレンダ、PNG生成、ページ分割、ログ出力

## 想定読者

このドキュメントは、実装の内部設計を把握したい上級ユーザーや保守者向けです。導入・操作手順のみが目的の場合は README を参照してください。

## アーキテクチャ

- yazi plugin `obsidian-preview`
  - `.md`選択時のデフォルトプレビュー担当
  - キャッシュ有効ならPNG表示
  - キャッシュ無効/欠損ならObsidianに再生成要求
- yazi plugin `obsidian-toggle`
  - `, p`でノート単位の表示モード切替（PNG/Markdown）
- yazi plugin `obsidian-nav`
  - `J/K` を直接 `obsidian-nav` で受けてページ移動
- yazi plugin `obsidian-refresh`
  - `, u`で対象ノートの再生成をトリガ（既存PNGは完了まで保持）
- yazi plugin `obsidian-tune`
  - `, = / , - / , 0` で読みやすさ（zoom）のみライブ調整
- Obsidian plugin `yazi-exporter`
  - コマンド `yazi-exporter:export-requested-to-cache`
  - 指定ノートをレンダしてPNGを生成
  - 長文ノートを `--p0000.png` 形式でページ分割

## 依存関係の設計

この実装は依存を「層」で分離しています。

1. 実行依存（ユーザー環境）
   - yazi + Obsidian Desktop
   - Local REST API plugin
   - `curl`, `jq`, `md5` または `md5sum`
2. ビルド依存（導入時のみ）
   - `node` / `npm`（Node.js >= 20.19.0。trusted prebuilt checksum が未指定/不一致、または `--force-build` 時）
   - `html2canvas`（レンダキャプチャ）
   - `esbuild` / `typescript`（Obsidian pluginビルド）
3. 配布依存（開発者向け）
   - `rsync` / `zip` / SHA-256コマンド（`shasum` / `sha256sum` / `openssl`）

重要ポイント:

- yazi plugin（Lua）はビルド不要で、そのまま配置可能
- npmが必要なのは Obsidian plugin `yazi-exporter` のビルド時のみ
- 実行中のプレビュー処理は npm に依存しない
- 配布物には `obsidian-plugin/yazi-exporter/prebuilt/main.js` を同梱（trusted checksum 検証成功時のみ npm 不要）

## 依存関係が必要な理由

- `yazi`
  - 実際のプレビュー実行環境
  - `obsidian-preview` / `obsidian-nav` / `obsidian-toggle` / `obsidian-refresh` / `obsidian-tune` を呼ぶ主体
- Obsidian Desktop
  - Markdownレンダリング本体（テーマ、コールアウト、数式、画像解決）
  - `yazi-exporter` は Obsidian API 上で動作
- Local REST API plugin
  - yazi側から前面化を抑えてコマンド起動する経路
  - `POST /commands/<command_id>` 呼び出しに使用
- `curl`
  - REST APIコール実行
- `jq`
  - Local REST API設定（APIキー/ポート）読み取りとJSON更新
- `md5`
  - vault相対パスからキャッシュキーを作る共通ハッシュ
- `node` / `npm`（任意）
  - Node.js >= 20.19.0
  - `--prebuilt-sha256` が未指定/不一致、または `--force-build` の場合に `yazi-exporter` ビルドで使用
- `rsync` / `zip` / SHA-256コマンド（`shasum` / `sha256sum` / `openssl`）（配布者向け）
  - リリースアーカイブ生成とハッシュ出力

## prebuiltアーティファクト方式

`yazi-exporter` は「ソースビルド」と「prebuilt配布」の2方式をサポートします。

1. trusted prebuilt方式（任意）
   - `install.sh --prebuilt-sha256 <trusted_hash>` で externally verified checksum を指定した場合のみ有効
   - checksum一致時に `prebuilt/main.js` をVaultへコピー
   - Node/npm不要
2. ソースビルド方式（既定フォールバック）
   - `--prebuilt-sha256` 未指定/不一致/検証不能時は `npm run build` にフォールバック
   - `install.sh --force-build` で常にソースビルドを強制可能

`scripts/package-release.sh` は配布前に `scripts/release-check.sh` を実行し、prebuilt を自動生成します。
同時に、外部配布向け trusted checksum アセット `obsidian-yazi-render-<VERSION>.prebuilt-main.js.sha256` を生成します。

## インストール導線

導線は2系統あります。

1. 標準導線（明示指定）
   - `scripts/install.sh --vault <path>`
   - CI/自動化向き
2. 簡易導線（対話・自動検出）
   - `scripts/install-easy.sh`
   - Vault自動検出、依存確認、`--auto-brew` で不足導入を補助
   - trusted prebuilt checksum が有効な場合のみ Node/npm チェックを自動スキップ
   - `--force-build` 指定時のみNode/npmを必須化
3. 安全更新（標準導線の既定）
   - `install.sh` は既存 `yazi.toml` / `keymap.toml` / `community-plugins.json` / 既存プラグイン配置をバックアップ
   - バックアップ先は `~/.obsidian-yazi-render-backups/<timestamp>`（`--backup-dir` で変更可能）
   - `--dry-run` で実変更なしの事前確認が可能

補助スクリプト:

- `scripts/doctor.sh`
  - 依存コマンド、Vault、Local REST API設定を検査
  - prebuilt有無に応じてNode/npmの必須判定を切替
  - `--require-build` でビルド系依存を強制検査
- `scripts/release-check.sh`
  - シェル構文、JSON構文、Lua構文（`luac` / `lua` / pinned `luaparse`）を検査
  - Obsidian plugin の `npm ci`、`npm run typecheck`、`npm run test`、`npm run build` を実行
  - Lua構文検査は strict mode 既定ON（`OBSIDIAN_RELEASE_CHECK_STRICT_LUA=1`）
  - ローカル作業ファイル（bridge/ssh/skill など）の混入を検出

## キャッシュレイアウト

既定:

- macOS: `~/Library/Caches/obsidian-yazi`
- Linux/その他POSIX: `${XDG_CACHE_HOME}/obsidian-yazi`（未設定時は `~/.cache/obsidian-yazi`）

- `img/<digest>.png`: 先頭ページ（互換用）
- `img/<digest>--p0000.png`: ページ分割画像
- `img/<digest>.meta.json`: ページ数などのメタ情報
- `mode/<digest>.md`: Markdown表示フラグ
- `locks/<digest>.lock`: 連打防止ロック
- `log/<digest>.json`: 生成デバッグログ
- `log/<digest>.error.json`: 生成失敗ログ
- `requests/current.txt`: 次に生成するvault相対パス
- `requests/current.json`: 生成要求の詳細（renderWidthPx, pageHeightPx, previewCols, previewRows）
- `requests/queue/<digest>.json`: リクエストキュー（同一ノートは上書き）

`digest` は vault相対パスの MD5（文字列）です。

## 生成フロー

1. yaziで `.md` をhover
2. modeフラグを確認
   - あり: Markdown表示
   - なし: PNG表示に進む
3. PNGが存在し、TTL内で、ノート更新より新しいならPNG表示
4. 上記以外なら `requests/current.txt` に相対パスを書き込み
   - `requests/current.json` に現在のプレビュー幅情報を書き込み
   - 同時に `requests/queue/<digest>.json` にも書き込み（同一ノートは上書き、失敗時はキュー掃除）
5. Obsidian Local REST API の `commands/<command_id>` を呼び出し
6. Obsidian pluginがレンダしてPNGを書き出し
7. 次回peekでPNG表示

## 再生成判定

再生成条件の主なルール:

- PNGが存在しない
- TTL超過（既定3日）
- `.md` 更新時刻 > `.png` 更新時刻
- renderer本体（`yazi-exporter/main.js`）の更新時刻 > `.png` 更新時刻
- `meta.json.renderWidthPx` と現在推定の表示幅の差が閾値を超過
- `meta.json.pageHeightPx` と現在推定のページ高さの差が閾値を超過

これにより、renderer改善後に古いキャッシュが残る問題を抑止します。

## レンダリング品質対策

`yazi-exporter` 側で以下を実装しています。

- 背面実行時のハング対策
  - `requestAnimationFrame` 待機にタイムアウト導入
  - エクスポート全体、markdown render、canvas capture にタイムアウト導入
- 画像崩れ対策
  - `![[...]]` 画像埋め込みを実体解決して描画
  - `app://` 画像をcapture前にdata URL化
- 長文ノート対策
  - ノート全体を1回キャプチャしてから、`pageHeightPx` ごとにPNG分割
  - `maxHeightPx = 0` を無制限として扱い、既定で末尾まで出力
- 文字間崩れ対策
  - host配下のletter/word spacingを補正
  - CJK表示時の異常な字間拡張を抑制

## 前面化回避

REST経由では `open` API を使わず、コマンド実行のみを行います。

- 利点: Obsidianが前面化しにくい
- fallback: REST失敗時は CLI (`obsidian` / `Obsidian.com`) と URI (`open` / `xdg-open` / `cmd.exe start`) を設定に応じてフォールバック
  - 既定は REST のみ（CLI/URI は opt-in）
  - URI/CLI の vault 指定には `OBSIDIAN_VAULT_NAME` を使用（既定: `obsidian`）

## セキュリティハードニング

- REST接続先の制限
  - 既定では loopback (`127.0.0.1`, `localhost`, `::1`) のみ許可
  - 非loopbackを使う場合は `OBSIDIAN_REST_ALLOW_REMOTE=1` が必要
- TLS検証の明示化
  - `OBSIDIAN_REST_VERIFY_TLS` 未設定時は loopback 接続で検証OFF、非loopback接続で検証ON
  - 非loopback + 検証OFF は拒否（明示的な安全緩和を防止）
- APIキー露出の低減
  - `curl -H "Authorization: ..."` の直接引数渡しを廃止
  - `curl -H @-` に標準入力で Authorization ヘッダを渡す
  - 同一ユーザーのプロセス一覧からの平文トークン露出を低減
- APIキー探索境界
  - 既定では active vault 設定と `OBSIDIAN_API_KEY` のみを使用
  - `$HOME` 配下の追加Vault探索は `OBSIDIAN_YAZI_ALLOW_HOME_KEY_SCAN=1` を明示した場合のみ有効
- キャッシュ権限の固定
  - yazi側・Obsidian側ともに `cache/img|mode|locks|log|requests` を `700` に補正
  - キャッシュ直下の読み取り範囲を最小化
- prebuilt整合性チェック
  - `install.sh` は同梱 `main.js.sha256` を信頼境界にせず、`--prebuilt-sha256`（外部で検証済みの trusted checksum）を要求
  - trusted checksum は GitHub Release アセット `obsidian-yazi-render-<VERSION>.prebuilt-main.js.sha256` から取得する
  - trusted checksum が未指定/不一致/形式不正のときは prebuilt を使わず `npm run build` へフォールバック

## キーバインド

- `R`: PNG/Markdown切替（単キー）
- `, p`: PNG/Markdown切替
- `J`: 次ページ
- `K`: 前ページ
- `, j`: 次ページ（Shift不要）
- `, k`: 前ページ（Shift不要）
- `U`: 再生成をリクエスト（単キー）
- `, u`: 再生成をリクエスト
- `, =`: 読みやすさを上げる（文字大きめ）
- `, -`: 読みやすさを下げる（情報量重視）
- `, 0`: zoom を既定値へ戻す

`j/k`（小文字）は通常のファイル移動を維持します。

## UXチューニング（チラつき軽減）

- `J/K` は `obsidian-nav` で直接 `peek` を進める
- `yazi.toml` で `image_delay = 40` を推奨
- PNGが古い場合も、再生成中は既存PNGを表示し続ける（`OBSIDIAN_YAZI_SHOW_STALE_IMAGE=1`）
- 再生成ステージを通知（`OBSIDIAN_YAZI_REFRESH_NOTIFY=1`, queued/rendering/writing/done）
- 再生成中は定期ポーリングで `peek` を再実行し、完了時に自動追従（`OBSIDIAN_YAZI_REFRESH_POLL_SECS`, 既定 `0.40`）
- ライブ調整キー（`, = / , -`）は `, u` 不要で即時再生成を要求し、進捗ステージを通知
- Obsidian 側が `log/<digest>.status.json` を更新し、yazi 側通知へ反映
- ライブ調整時のみ高速プロファイル（低待機・低負荷キャプチャ）を適用（`OBSIDIAN_YAZI_TUNE_FAST_MODE=1`）
- tmux 内では `allow-passthrough` を実行時に検査し、不足時は1回だけ警告を表示
- ライブ調整時は yazi 側で tuning キャッシュを強制更新し、同秒更新でも値が反映される
- `readabilityZoom` を export request / meta に保存し、Obsidian 側 render host へ直接スケール適用して確実に文字サイズへ反映
- ズーム上限を引き上げ（`2.40x`）し、視覚倍率マッピングを調整して「大きく変わるが1ステップは過激すぎない」挙動へ調整
- Auto-fit（既定ON）で preview pane の列/行変化を検知し、高速再生成で幅・高さを新サイズへ追従
- `targetPage` を render request に含め、ページPNGを「現在ページ周辺のみ」生成（高品質のまま初回表示高速化＋キャッシュ軽量化）
- 通知に `width/page` の適用値と変化率を表示し、体感差が小さい場合は `small visual delta` を明示
- Markdownモード中は PNGプレビューへ戻す案内を通知して反映されない理由を明確化
- stale時の再生成リクエストは先頭ページでのみ実行（ページ送り中の差し替えを抑制）
- `obsidian-preview` は同一画像（同一パス・mtime・表示領域）の再描画をスキップし、無駄な点滅を抑制
- Warp環境では `TERM=xterm-kitty` で yazi を起動すると `KGP` 経路になりやすい（`xterm-256color` だと `IIP` になることが多い）
- `obsidian-nav` は直近の要求ページを短時間保持し、キー連打時の重複 `peek` を減らす（`OBSIDIAN_YAZI_NAV_PENDING_MS`, 既定650ms）
- 1ページの縦横比は `previewRows/previewCols * TERM_CELL_ASPECT * PAGE_HEIGHT_BIAS` を基準にしつつ、`previewRows/previewCols * TERM_CELL_ASPECT * MIN_PANE_FILL_RATIO` を下限として適用
- その後 `MIN_PAGE_RATIO..MAX_PAGE_RATIO` で制限して、横長/縦長どちらでも読みやすい範囲に収める

## 主要環境変数

- `OBSIDIAN_VAULT_ROOT`
- `OBSIDIAN_YAZI_CACHE`
- `OBSIDIAN_YAZI_TTL_DAYS`
- `OBSIDIAN_YAZI_LOCK_SECS`
- `OBSIDIAN_YAZI_LOCK_QUICK_RETRY_SECS`
- `OBSIDIAN_YAZI_REFRESH_NOTIFY`
- `OBSIDIAN_YAZI_REFRESH_POLL_SECS`
- `OBSIDIAN_YAZI_LAYOUT_SETTLE_SECS`
- `OBSIDIAN_YAZI_TRANSPORT_RETRY_SECS`
- `OBSIDIAN_YAZI_AUTO_FIT`
- `OBSIDIAN_YAZI_PANE_COLS_TOLERANCE`
- `OBSIDIAN_YAZI_PANE_ROWS_TOLERANCE`
- `OBSIDIAN_YAZI_COMMANDID`
- `OBSIDIAN_YAZI_RENDERER_JS`
- `OBSIDIAN_YAZI_USE_REST`
- `OBSIDIAN_YAZI_CLI_FALLBACK`
- `OBSIDIAN_YAZI_AUTO_CLI_FALLBACK`
- `OBSIDIAN_YAZI_CLI_BIN`
- `OBSIDIAN_YAZI_URI_FALLBACK`
- `OBSIDIAN_YAZI_AUTO_URI_FALLBACK`
- `OBSIDIAN_YAZI_DEBUG_INCLUDE_PATHS`
- `OBSIDIAN_VAULT_NAME`
- `OBSIDIAN_YAZI_PREFER_ENV_API_KEY`
- `OBSIDIAN_YAZI_ALLOW_HOME_KEY_SCAN`
- `OBSIDIAN_API_KEY`
- `OBSIDIAN_REST_HOST`
- `OBSIDIAN_REST_PORT`
- `OBSIDIAN_REST_INSECURE`
- `OBSIDIAN_YAZI_REFRESH_NOTIFY_VERBOSE`
- `OBSIDIAN_YAZI_BASE_WIDTH_PX`
- `OBSIDIAN_YAZI_BASE_COLS`
- `OBSIDIAN_YAZI_PX_PER_COL`
- `OBSIDIAN_YAZI_RENDER_SCALE`
- `OBSIDIAN_YAZI_RENDER_SCALE_WEZTERM`
- `OBSIDIAN_YAZI_RENDER_SCALE_WARP`
- `OBSIDIAN_YAZI_RENDER_SCALE_GHOSTTY`
- `OBSIDIAN_YAZI_READABILITY_ZOOM`
- `OBSIDIAN_YAZI_READABILITY_WIDTH_WEIGHT`
- `OBSIDIAN_YAZI_TUNE_STEP`
- `OBSIDIAN_YAZI_TUNE_FAST_MODE`
- `OBSIDIAN_YAZI_MIN_WIDTH_PX`
- `OBSIDIAN_YAZI_MAX_WIDTH_PX`
- `OBSIDIAN_YAZI_RENDER_WIDTH_TOLERANCE_PX`
- `OBSIDIAN_YAZI_DYNAMIC_PAGE_HEIGHT`
- `OBSIDIAN_YAZI_TERM_CELL_ASPECT`
- `OBSIDIAN_YAZI_PAGE_HEIGHT_BIAS`
- `OBSIDIAN_YAZI_MIN_PANE_FILL_RATIO`
- `OBSIDIAN_YAZI_PAGE_TALLNESS`
- `OBSIDIAN_YAZI_TALL_STEP`
- `OBSIDIAN_YAZI_MIN_PAGE_RATIO`
- `OBSIDIAN_YAZI_MAX_PAGE_RATIO`
- `OBSIDIAN_YAZI_MIN_PAGE_HEIGHT_PX`
- `OBSIDIAN_YAZI_MAX_PAGE_HEIGHT_PX`
- `OBSIDIAN_YAZI_PAGE_HEIGHT_TOLERANCE_PX`

## 運用コマンド

インストール:

```bash
./scripts/install.sh --vault "/path/to/vault" --install-launchd
```

パッケージ作成:

```bash
./scripts/package-release.sh <VERSION>
```

署名付きチェックサムを出す場合（任意）:

```bash
MINISIGN_SECRET_KEY="/path/to/minisign.key" ./scripts/package-release.sh <VERSION>
```

キャッシュ掃除のみ:

```bash
./scripts/cleanup-cache.sh
```

レンダ/表示の簡易診断:

```bash
./scripts/debug-yazi-status.sh --no-trigger --loops 20
./scripts/debug-yazi-error.sh
```

## 2026-02-22 回顧（試行錯誤ログ）

今回の不具合は、`2026-02-22` 時点で以下が重なって発生しました。

### 主な症状

- `U` で再生成したつもりでも見た目が変わらない
- `J/K` が効かない、または期待通りにページ移動しない
- 文字が異様に小さい、またはCJKで文字間が不自然に広がる
- テキストサイズ変更後にページ末尾が欠ける（途中までしか描画されない）

### なぜ悪化したか（根本原因）

- キーマップ競合
- `J/K` を yazi 既定 `seek` に依存したままにしており、環境差や他設定の影響を受けやすかった
- `keymap` 本体と `mgr.prepend_keymap` の二重定義が混在し、どちらが効いているか分かりにくかった
- 再生成トリガの見えにくさ
- REST が不達でも stale PNG を保持する経路があり、失敗が体感で「無反応」に見えた
- レンダ幅推定の過大評価
- 分割ペイン時に `renderWidthPx` が大きく見積もられ、結果的に文字が小さく出た
- タイポグラフィ補正のやり過ぎ
- host配下の全要素に強い spacing 補正をかけたことで、CJKの文字間表示が崩れた
- ページ生成戦略の副作用
- 周辺ページのみ生成する最適化が、長文・拡大時に「末尾欠け」として見えた

### 何を変えたら改善したか（有効だった修正）

- キー経路を明示化
- `J/K` を `plugin obsidian-nav -- next/prev` に直接バインド
- `,j / ,k` も追加し、Shift不要の代替経路を用意
- `U/R` と `,u/,p` を併用して、操作経路の体感を安定化
- 再生成失敗の前面通知
- REST失敗時に URI fallback 通知を追加（現在は opt-in。既定は `OBSIDIAN_YAZI_URI_FALLBACK=0` / `OBSIDIAN_YAZI_AUTO_URI_FALLBACK=0`）
- トリガ失敗時に英語通知で理由を明示
- 幅推定の再調整
- `OBSIDIAN_YAZI_PX_PER_COL` 既定値を引き下げ
- 列比率を平方根スケーリング化し、狭いペインで過度に小さくならないよう補正
- tmux分割向けの上限キャップを強化
- 文字描画ロジックの見直し
- `css zoom` 依存をやめ、`font-size + width compensation` に統一
- テキスト整形CSSは段落/見出し系へ限定し、全要素一括補正を撤回
- ページ欠け対策
- 非fastモードでは通常ノートサイズ（最大64ページ）を全ページ書き出し

### 今回の教訓（再発防止）

- 「高速化」と「表示安定」は同時最適化が必要。片側だけ触ると回帰しやすい
- キーバインドは `default keymap` 依存を減らし、プラグイン呼び出しを明示する
- レンダ幅推定は「理論値」ではなく「分割ペイン体感」で保守的に設計する
- CJK系は文字間補正を全要素に強制しない（対象要素限定が安全）
- 最適化（部分ページ生成）は欠けの回帰テストとセットで導入する
- 失敗時は必ず「英語の具体メッセージ」を出して、無反応に見せない

## 超詳細: 現在設計と苦労している部分

このセクションは「現状の設計判断」と「実際に苦労している点」を、実装レベルで残すためのメモです。
対象日付は `2026-02-22` 時点です。

### 1. 設計思想（なぜこの構成か）

1. 使う側は「設定しなくても勝手にうまくいく」を最優先にする
2. 分割ペイン利用（tmux/yazi多窓）でも、同じ操作感を維持する
3. 失敗時は「黙る」のではなく、短い英語通知で原因を出す
4. 画質と速度はトレードオフだが、通常運用では品質側を維持する
5. キャッシュは使うが、肥大化と古い表示固定を避ける

### 2. レイヤー境界（責務分離）

1. yazi層（Lua）
2. 役割: 「何を表示するか」を決める
3. 詳細: キー処理、stale判定、再生成要求、通知、PNG表示/Markdownフォールバック
4. Obsidian層（TypeScript）
5. 役割: 「どう描画するか」を実行する
6. 詳細: Markdownレンダ、画像解決、html2canvas、ページ分割、meta/status書き込み
7. ファイル通信層（cache/requests）
8. 役割: yaziとObsidianの非同期連携バッファ
9. 詳細: `current.txt`, `current.json`, `queue/*.json`, `lock`, `status`

### 3. 主要データ契約（壊れやすいポイント）

1. `requests/current.json`
2. 必須: `path`
3. 重要: `renderWidthPx`, `pageHeightPx`, `readabilityZoom`, `renderProfile`, `targetPage`
4. 意味: yaziの「いまの表示領域と意図」をObsidian側へ渡す
5. `img/<digest>.meta.json`
6. 必須: `renderWidthPx`, `pageCount`
7. 重要: `pageHeightPx`, `readabilityZoom`, `generatedPages`, `writeAllPages`
8. 意味: 次回peekで stale判定・ページ存在判定に使う
9. `log/<digest>.status.json`
10. 重要: `state`, `stage`, `error`
11. 意味: 再生成中UIと失敗通知の唯一の根拠

### 4. 状態遷移（実際の動き）

1. `idle`
2. ユーザーが `.md` をhover
3. `mode-check`
4. `mode/<digest>.md` があれば Markdown 表示
5. `cache-check`
6. PNGとmetaを確認し、freshならそのまま表示
7. `stale-detected`
8. staleなら `lock` を確認して再生成要求を送信
9. `refreshing`
10. 既存PNGを表示しつつ `status.json` をポーリング
11. `done`
12. `status.state=done` になったら自動peekで差し替え
13. `error`
14. `status.state=error` または request失敗時に通知し、旧PNGを維持

### 5. 幅・高さ推定ロジック（現行）

1. 幅推定は2経路を混ぜる
2. `baseline_scaled = BASE_WIDTH * sqrt(cols / BASE_COLS)`（狭ペインの過補正抑制）
3. `by_cols_scaled = cols * PX_PER_COL`
4. `scaled_width = max(baseline_scaled, by_cols_scaled)`
5. readability適用: `scaled_width / (zoom ^ weight)`
6. 端末差補正: `scaled_width = scaled_width * terminal_scale`（`RENDER_SCALE*`、既定は端末問わず 1.00）
7. min/max clamp適用
8. tmux時は追加cap: `min(render_width, cols * 8.0)`
9. 高さ推定は `rows/cols` とセル縦横比、bias、ratio clamp、pageTallnessで決定

### 6. ズームの伝播（キー押下から見た目変更まで）

1. `,=` / `,-` / `,0`
2. `obsidian-tune` が `mode/.live-tuning.json` を更新
3. 同時に `peek(force_regen=true)` を発火
4. `obsidian-preview` が tuning を読み、request payloadに `readabilityZoom` を格納
5. Obsidian exporter が `readabilityZoom` を host `font-size` と幅補正に適用
6. 新PNG/meta生成後、yazi側が自動差し替え
7. 成否は英語通知で可視化

### 7. ナビゲーションの設計（J/K問題への対応）

1. 依存方針
2. 旧: `seek` 依存
3. 現: `plugin obsidian-nav -- next/prev` へ直接バインド
4. 互換キー
5. `J/K` に加えて `,j/,k` を提供（Shift不要）
6. 挙動
7. 先頭/末尾到達時は通知
8. 画像未生成時は `Press U to regenerate` を通知
9. 連打時は短時間キャッシュで重複peek抑制

### 8. 再生成トリガの設計（U問題への対応）

1. `U` / `,u` で対象ノートの meta/lock/log をクリア
2. 旧PNGは残して表示継続し、「真っ白化/テキスト戻り」を減らす
3. RESTを先に試す
4. REST失敗時は URI fallback (`open -g`) を通知付きで試行可能（現在は opt-in）
5. 両方失敗したら英語エラー通知を出す
6. lockは失敗時に解除し、再試行をブロックしない

### 9. 速度最適化の現在値

1. quick mode時は pixelRatioを抑える
2. render wait / frame wait / font wait を短縮
3. inline image処理数を制限
4. auto profileで fast/balanced/quality を選択
5. 非fastかつ通常ページ数（<=64）は全ページ書き出しで再移動コスト削減
6. stale時の再描画は同一画像シグネチャならスキップ

### 10. 品質最適化の現在値

1. Reading View clone優先（可能なとき）
2. 画像埋め込みは `![[...]]` を実体解決
3. `app://` / `file://` 画像を data URL化してcapture安定化
4. fallbackレンダ (`<pre>`) を保持し、空レンダを避ける
5. タイポグラフィ補正は段落/見出し系に限定（全要素強制を撤回）

### 11. セキュリティ設計の実際

1. request pathは vault相対のみ許可
2. REST hostはloopbackを既定許可、remoteは明示opt-in
3. API keyはコマンドラインに直書きせず、`curl -H @-` + stdin で渡す
4. cache配下は原則 `700`、sentinel/headerは `600`
5. stale requestを時刻で破棄し、古い操作の遅延反映を防ぐ

### 12. いま苦労している点（本質）

1. yazi keymap優先順位の見えにくさ
2. `keymap` 本体と `mgr.prepend_keymap` の重なりで体感差が出る
3. 端末実装差（Warp/kitty/chafa）の挙動ばらつき
4. 見た目差分が「実装バグ」か「端末表示差」か切り分けに時間がかかる
5. Obsidian側の実行状態依存
6. Local REST APIが落ちていると、ユーザー視点では「押しても効かない」に見えやすい
7. html2canvas由来の限界
8. テーマ/CSSスニペット/フォントにより文字組みの再現差が出る
9. CJK最適化の難しさ
10. 一律補正は副作用が大きく、要素限定補正でも完全再現は難しい
11. 高速化と欠け回避の両立
12. 周辺ページのみ生成は速いが欠けやすい。全ページ生成は安定だが重い
13. ロック・再生成競合
14. 連打時に stale判定、lock、status更新のタイミング競合が起こりやすい
15. ローカル設定ドリフト
16. `~/.config/yazi/keymap.toml` をユーザーが直接編集すると再現が割れる

### 13. どこが「設計上の負債」か

1. file-based IPCは単純で強いが、状態整合の責任が重い
2. 通知駆動で体感は良いが、通知頻度チューニングが難しい
3. 自動最適化は便利だが、推定が外れると「勝手に悪化」に見える
4. 端末画像表示を前提にしているため、UI品質が外部要因に左右される

### 14. 再発防止の運用ルール（実務）

1. 表示系変更を入れたら、以下3条件で必ず確認
2. 狭いペイン（分割）での見え方
3. `J/K` と `U` の効き方
4. CJKノートの字間
5. キャッシュを消しての初回生成と2回目表示の差
6. REST停止時の fallback 動作（英語通知含む）
7. 新機能追加時は「通知文」も先に決める
8. 変更後は `status.json` と `meta.json` の実値を確認する

### 15. 今後の改善優先順位

1. 優先度A
2. keymapの一本化（冗長定義を減らす）
3. 端末差を吸収する最小設定セットの固定化
4. 優先度B
5. render幅推定の学習的チューニング（前回実測との差分補正）
6. `zoom` 体感差を数値化した通知（小差分時の案内強化）
7. 優先度C
8. status更新をより細かくして、待ち時間の不安をさらに減らす
9. WebSocket等による完了通知（ポーリング依存の縮小）

## 2026-02-22 追加実装（計画反映）

### 1. キーマップ一本化の実装

- `scripts/install.sh` に `strip_legacy_obsidian_key_lines()` を追加
- 旧行の自動削除は、`# obsidian-yazi-render:legacy` / `# obsidian-yazi-render:managed` の明示マーカー付き行だけを対象に限定
- これにより `J/K/U/R` が環境差で効いたり効かなかったりする再発を抑制

### 2. tmux 経路診断の強化

- `scripts/doctor.sh` に以下を追加:
  - `allow-passthrough` 検査
  - `default-terminal` / `TERM` の妥当性チェック
  - yazi 側 preloader 設定と keymap 重複検査
- 実行時（`obsidian-preview`）にも tmux 設定不足を1回だけ警告表示

### 3. 再生成ステータスの信頼性向上

- `status.json` 解析に `requestId` を追加
- lock 側 `requestId` と status 側 `requestId` の同期状態を通知に反映
- 通知は英語に統一し、記号依存を廃止（例: `Regenerating preview: ...`, `Preview updated in ...s.`）

### 4. ライブ調整の体感改善

- `obsidian-tune` の最小実効ステップを split pane 向けに自動補正
- 通知に `Step` を表示して「効いたか不明」を低減
- `obsidian-refresh` は `force_regen=true` で確実に再生成フローへ入る
- `force_regen` が tune 起点かどうかを判別し、`U` 押下時に tune専用通知が混ざらないよう修正

### 5. 長文レンダ欠け対策（重要）

- Obsidian exporter の capture 制御を変更:
  - 旧: safety 上限超過で `captureHeight` を切り捨て（末尾欠けの原因）
  - 新: まず `scale` を自動縮小して全体を収める方針へ変更
  - それでも安全域を超える場合のみ最小限クリップ
- `meta.json` / `status.json` に `captureScale`, `clippedByMaxHeight`, `clippedBySafety` を記録
- ページ高さ計算は `effectivePixelRatio` ではなく実際の `appliedScale` を使用し、ページ分割の整合性を改善

### 6. 速度と品質のバランス調整

- inline image cache 上限を `96MB -> 64MB` へ削減（メモリ圧迫抑制）
- quick mode の周辺ページ生成半径を `1 -> 2` に拡大（ページ送り体感改善）
- `OBSIDIAN_YAZI_REFRESH_POLL_SECS` 既定を `0.40` へ短縮（完了追従を高速化）

## 2026-02-23 問題点と解決策まとめ（確定版）

### 1. `U` 再生成時に「無反応」に見える

- 症状:
  - 押しても見た目が変わらない
  - stale PNG が残り、失敗が分かりにくい
- 原因:
  - REST失敗時の体感が silent に近かった
  - 再生成状態の可視化が弱い
- 解決:
  - `status.json` ベースの段階通知（queued/rendering/writing/done/error）
  - REST不達時の URI fallback 通知（現在の自動移行は opt-in 設定時のみ）
  - `obsidian-refresh` で `force_regen=true` を明示し再生成経路を固定

### 2. ライブ調整で数値だけ変わり、見た目が変わらない

- 症状:
  - `Applying tune` は出るが文字サイズ差が見えない
- 原因:
  - ズーム刻みが分割ペインで小さすぎるケース
  - width補正とズーム補正の組み合わせで視覚差分が圧縮されるケース
- 解決:
  - `obsidian-tune` で最小実効ステップを自動補正
  - 通知に `Zoom` と `Step` を表示
  - `applyReadabilityTuning` の補正係数を再調整して視覚差を強化

### 3. 文字間が異常に広がる（CJK崩れ）

- 症状:
  - 日本語の字間が不自然に拡張される
- 原因:
  - quick mode キャプチャ経路と文字組みの相性
  - タイポグラフィ補正の適用不足
- 解決:
  - CJKテキスト検出時は `foreignObjectRendering` を優先
  - 失敗時は `capture-canvas-fallback` へ自動退避
  - render host に `letter-spacing/word-spacing/text-align` 正規化を追加

### 4. 大きい文字サイズで末尾が欠ける

- 症状:
  - 下端まで描画されない、ページ途中で切れる
- 原因:
  - 旧実装が安全制約到達時に高さを切り捨てていた
- 解決:
  - 先に `captureScale` を自動調整し、全体収容を優先
  - どうしても超過する場合のみ最小限クリップ
  - `meta/status` に `captureScale`, `clippedBy*` を記録

### 5. `Shift+J/K` が効かない

- 症状:
  - `J/K` がページ送りではなく何も起きない、または別動作
- 原因:
  - `keymap` 優先順位で標準 `seek` と競合
  - `prepend_keymap` 依存のため環境差が出る
- 解決:
  - installer で legacy の `J/K seek` 行を除去
  - `mgr.prepend_keymap` の managed block に `J/K` / `<S-j>/<S-k>` / `,j/,k` を集約
  - 既存設定が assignment 形式（dotted/table）の場合は自動マージを中断し手動統合へ誘導

### 6. tmux 分割時の自動最適化が不安定

- 症状:
  - 分割後に見づらいサイズのまま、または過剰縮小
- 原因:
  - 端末プロトコル差と tmux passthrough 条件不足
  - 単発推定の幅計算だけでは収束しにくい
- 解決:
  - `doctor.sh` で `allow-passthrough` / `TERM` / keymap重複を診断
  - 実行時にも tmux 設定不足を1回通知
  - 直近 meta を使った width/page の補正ブレンドを導入

### 7. 高速化と品質の両立

- 調整:
  - `OBSIDIAN_YAZI_REFRESH_POLL_SECS=0.40`
  - quick mode 周辺ページ半径 `2`
  - inline image cache 上限 `64MB`
- 効果:
  - 待ち時間の体感を短縮しつつ、ページ移動時の空振りを低減
  - メモリ圧迫を抑えながら品質劣化を最小化

### 8. 再発防止ルール（今回確定）

- `J/K` は managed block で一元管理し、既存assignment形式との競合は手動統合へ明示誘導する
- CJK ノートは quick mode でも FO 経路を優先し、失敗時フォールバックを持つ
- `status.json` と `meta.json` の実値で「効いているか」を必ず判断する
- 「通知で成功を見せる」だけでなく、`requestId` 一致で経路整合まで検証する

## 既知の制約

- ObsidianのLive Previewと完全ピクセル一致は保証しない
- 一部テーマやCSSスニペットで差異が出る可能性あり
- ターミナル画像表示品質は端末実装（Warp/kitty/sixel）に依存
- Local REST API無効時はURI fallbackが有効なら再生成可能

## デバッグ観点

確認ファイル:

- `$OBSIDIAN_YAZI_CACHE/log/<digest>.json`（未設定時: macOS `~/Library/Caches/obsidian-yazi`, Linux `${XDG_CACHE_HOME}/obsidian-yazi` または `~/.cache/obsidian-yazi`）
- `$OBSIDIAN_YAZI_CACHE/log/<digest>.error.json`
- `$OBSIDIAN_YAZI_CACHE/log/request-trace.json`（`Enable debug logs=ON` のとき）
  - 既定ではノートパス・requestパスは `<redacted>` を記録
  - 明示的に `OBSIDIAN_YAZI_DEBUG_INCLUDE_PATHS=1` を設定した場合のみパス情報を出力

確認ポイント:

- `stage` が `done` になっているか
- `firstImageNaturalWidth` が0でないか
- `pageCount` が1以上か
- `scrollWidth` が異常値でないか
