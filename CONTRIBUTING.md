# Contributing

Obsidian Yazi Render へのコントリビューションを歓迎します。

## バグ報告・機能リクエスト

[GitHub Issues](https://github.com/codikzng/obsidian-yazi-render/issues) から報告してください。

バグ報告には以下を含めてください:

- OS とバージョン
- yazi のバージョン（`yazi --version`）
- 使用ターミナル（Ghostty / WezTerm / Kitty 等）
- `./scripts/doctor.sh --vault "/path/to/vault"` の出力
- 再現手順

## 開発環境のセットアップ

### 前提条件

- Node.js >= 20.19.0
- `jq`、`rsync`（インストーラが使用）、`curl`（REST 経路のランタイム）

```bash
git clone https://github.com/codikzng/obsidian-yazi-render.git
cd obsidian-yazi-render

# Obsidian プラグインのビルド
cd obsidian-plugin/yazi-exporter
npm install
npm run build

# インストール（開発用 Vault を指定）
cd ../..
./scripts/install.sh --vault "/path/to/your/vault"
```

> [!TIP]
> CI では `npm ci` を使用します。ローカル開発では `npm install` で問題ありません。

## プルリクエスト

1. フォークして feature ブランチを作成
2. 変更を加える
3. `./scripts/doctor.sh` でインストール状態を確認
4. PR を作成（変更内容と動作確認した環境を記載）

> [!NOTE]
> yazi プラグイン（Lua）の変更は yazi の再起動が必要です。ソースの編集後は `./scripts/install.sh` で再インストールしてください。

## コードスタイル

- **Lua**（yazi プラグイン）: インデントはスペース 2 つ
- **TypeScript**（Obsidian プラグイン）: プロジェクトの `tsconfig.json` に準拠
- **Shell**（スクリプト）: ShellCheck 準拠を推奨

## ライセンス

コントリビューションは MIT License のもとで提供されます。
