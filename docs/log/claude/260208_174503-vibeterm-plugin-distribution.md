# vibeterm-telemetry プラグインを vibeterm iOS リポジトリに配置

**日時**: 2026-02-08 17:45
**作業**: clawgate の vibeterm-telemetry プラグインを vibeterm リポジトリに配布用としてコピー

## 変更内容

### vibeterm リポジトリ (`/Users/usedhonda/projects/ios/vibeterm`)

新規ファイル:
- `openclaw-plugin/index.js` — プラグインエントリ
- `openclaw-plugin/package.json` — 配布用（`workspace:*` 削除、名前を `@vibeterm/openclaw-telemetry` に変更）
- `openclaw-plugin/openclaw.plugin.json` — マニフェスト
- `openclaw-plugin/src/handler.js` — POST /api/telemetry ハンドラ
- `openclaw-plugin/src/store.js` — in-memory ストア（UUID dedup + circular buffer）
- `openclaw-plugin/src/auth.js` — Bearer token 認証
- `openclaw-plugin/README.md` — ユーザー向けインストールガイド
- `openclaw-plugin/install.sh` — ワンコマンドインストールスクリプト

### package.json の変更点（clawgate版との差分）

- `name`: `@openclaw/vibeterm-telemetry` -> `@vibeterm/openclaw-telemetry`
- `devDependencies`: `"openclaw": "workspace:*"` 削除（外部リポジトリでは不要）
- `openclaw.install.localPath`: `extensions/vibeterm-telemetry` -> `openclaw-plugin`

## 検証結果

vibeterm リポジトリから `install.sh` を実行:
1. プラグインコピー: 6ファイル → `~/.openclaw/extensions/vibeterm-telemetry/`
2. openclaw.json 登録: 既に登録済み（スキップ）
3. gateway 再起動: launchctl 経由で成功

curl テスト:
- 正常送信: `{"received":1,"nextMinIntervalSec":60}` ✓
- Dedup: `{"received":0,"nextMinIntervalSec":60}` ✓
- 認証エラー: `{"error":{"code":"UNAUTHORIZED",...}}` ✓
- メソッドエラー: `{"error":{"code":"METHOD_NOT_ALLOWED",...}}` ✓

Gateway ログ:
- `vibeterm-telemetry: registered POST /api/telemetry` ✓
- `clawgate: paired successfully` ✓
- `doctor OK (6/6 checks passed)` ✓
- `initial cursor=85` ✓
