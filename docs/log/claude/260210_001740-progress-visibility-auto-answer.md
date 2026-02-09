# Progress Visibility + Auto-Answer Implementation

**Date**: 2026-02-10
**Task**: running 中の進捗を Chi に見せる + auto モードの AskUserQuestion 自動回答

## Changes

### TmuxInboundWatcher.swift
- **Progress Timer**: 20秒間隔で running セッションの pane 出力を取得、変化があれば `source: "progress"` で EventBus に emit
  - `DispatchSource.makeTimerSource(queue: BlockingWork.queue)` で NIO ブロック回避
  - `hashValue` 比較で変化なしの場合はスキップ
  - ignore モード以外の全モードが対象
- **Auto-Answer**: auto モードで question 検出時、Chi に送らずローカル自動回答
  - キーワードスキャン: "(recommended)", "don't ask", "always", "yes", "ok", "proceed", "approve"
  - マッチなし -> 最初の選択肢を選択
  - `sendSpecialKey` で Up/Down + Enter 送信
- completion 時に `lastProgressHash` をクリア

### gateway.js
- Poll loop に `source: "progress"` イベントハンドラ追加
  - `setProgressSnapshot()` で保存のみ、AI にはディスパッチしない
  - `sessionStatuses` を "running" に設定
- `handleTmuxCompletion()` に `clearProgressSnapshot()` 追加

### context-cache.js
- `progressSnapshots` Map 追加
- `setProgressSnapshot()` / `clearProgressSnapshot()` 関数 export
- `getProjectRoster()` に `progressText` フィールド追加（running 中のみ）

### context-reader.js
- `buildProjectRoster()` に `progressText` 対応
  - running 中プロジェクトの最後 5行の出力をロスター内にインデント表示

### smoke-test.sh (bug fix)
- `grep -c` の出力に改行が含まれ整数比較が失敗するバグを `tr -d '[:space:]'` で修正

## Design Decisions

| Mode | Progress | Question | Rationale |
|------|----------|----------|-----------|
| ignore | - | - | 検出するが無視 |
| observe | emit | Chi に聞く | 読むだけ、介入不可 |
| auto | emit | 自動回答 | 機械的に動かし続ける |
| autonomous | emit | Chi に聞く | AI 設計タスク、判断必要 |

## Verification
- Build: OK
- Smoke test: 5/5 PASS (with OpenClaw)
- Gateway: doctor OK + initial cursor confirmed
