# gog-secretary ラッパー作成

## 日時
2026-02-08 13:49 JST

## 指示
LINE 秘書ボット用に `gog` CLI のロールベースラッパー `gog-secretary` を作成。
秘書業務に必要な操作のみ自動許可し、危険な操作はブロック。

## 変更内容

### 1. `/usr/local/bin/gog-secretary` (新規作成)
- allowlist ベースのラッパースクリプト
- 許可: calendar read/create/update, tasks CRUD(-delete), gmail search/drafts, drive metadata, contacts search, chat spaces, time/version
- ブロック: calendar delete/respond, gmail send/get, drive download/upload/delete/share, contacts list/bulk, chat messages, auth, config
- 全呼び出しを `~/.openclaw/logs/gog-secretary.log` に監査記録（printf %q でログ偽装防止）

### 2. `~/.openclaw/openclaw.json`
- safeBins: `"gog"` を削除 → `"gog-secretary"` に置換
- `gog` は都度確認（ask モード）に降格

### 3. Gateway 再起動
- `pkill -f "openclaw.*gateway"` → KeepAlive で自動復帰 → HTTP 200 確認

## 検証結果

| テスト | 結果 |
|--------|------|
| `gog-secretary calendar events` | PASS（gog に到達） |
| `gog-secretary tasks add` | PASS（gog に到達） |
| `gog-secretary version` | PASS（v0.9.0 出力） |
| `gog-secretary gmail send` | BLOCKED |
| `gog-secretary calendar delete` | BLOCKED |
| `gog-secretary drive download` | BLOCKED |
| `gog-secretary contacts list` | BLOCKED |
| `gog-secretary auth` | BLOCKED |
| `gog-secretary`（引数なし） | Usage 表示 |
| 監査ログ | 全9呼び出し記録 |
| Gateway 復帰 | HTTP 200 |

## 将来の改善（スコープ外）
- rate limiting（calendar create 6回/時間等）
- 外部 attendee ブロック
- bot-created イベントのタグ付け
- curl egress control
- OAuth スコープ分離
