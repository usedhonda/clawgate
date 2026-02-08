# 位置情報の日記書き込み実装

## 指示
- telemetry 受信時に `~/.openclaw/workspace/memory/YYYY-MM-DD.md` に位置エントリを追記
- スロットル: 200m移動 or 30分経過で書き込み
- AGENTS.md に Location Awareness ルール追加
- TOOLS.md に Vibeterm Telemetry セクション追加

## 変更ファイル
- `extensions/vibeterm-telemetry/src/handler.js` — haversine距離計算 + maybeWriteDiary() 追加
- `/Users/usedhonda/projects/ios/vibeterm/openclaw-plugin/src/handler.js` — 同期コピー
- `~/.openclaw/workspace/AGENTS.md:39-44` — Location Awareness セクション追加
- `~/.openclaw/workspace/TOOLS.md:32-36` — Vibeterm Telemetry セクション追加

## 実装詳細
- `maybeWriteDiary(sample, log)`: fire-and-forget で日記追記
- スロットル条件: lastDiaryWrite から 200m未満 AND 30分未満 → スキップ
- エントリ形式: `📍 HH:MM - lat, lon (accuracy Xm)`
- タイムゾーン: JST (Asia/Tokyo)
- ディレクトリ自動作成: `fs.mkdir(recursive: true)`

## 検証結果
- dev-deploy.sh: 6/6 PASS
- 初回 telemetry → 日記追記 OK
- 同位置再送 → スロットルで追記されず OK
- 10km移動 → 日記追記 OK

## 課題
- なし
