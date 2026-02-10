# Observe モードでの Claude Code 出力可視性改善

**Date**: 2026-02-10
**Branch**: main

## 変更内容

Chi（OpenClaw AI）が observe モードのセッションについて、ロスター行しか見えず
Claude Code の実際の出力が見えない問題を修正。

### 根本原因（3つのギャップ）

1. progress イベントがロスターに格納のみで AI dispatch されない
2. completion の extractSummary が末尾15行/1000文字と小さすぎる
3. ロスターの progressText が `running` 時のみ表示

### 修正

| ファイル | 変更 |
|---------|------|
| `TmuxInboundWatcher.swift:361,369` | extractSummary: 15行->30行, 1000->2000文字 |
| `gateway.js` | `shouldDispatchProgress()` + `handleTmuxProgress()` 新規追加 |
| `gateway.js` (polling loop) | progress イベントで非-ignore モードの場合 60秒間隔で AI dispatch |
| `gateway.js` (handleTmuxCompletion) | `clearProgressSnapshot` -> `setProgressSnapshot` で最終出力を保持 |
| `context-cache.js:144` | `progressText` を全状態で表示（`running` 限定を解除） |
| `gateway.js` (completion prefixes) | 長大なモード説明を `[OpenClaw Agent - Mode]` に簡素化 |
| `CLAUDE.md` | OpenClaw Agent セクションにモード行動指針テーブル追加 |

### 効果

- observe モード: 60秒ごとの progress 通知 + 30行/2000文字の completion サマリー
- ロスター: `waiting_input` 時も最終出力表示
- プレフィックス: シンプルなタグ、モード指示は CLAUDE.md に集約

### 検証

- `node --check` gateway.js, context-cache.js: OK
- `swift build`: OK
- `dev-deploy.sh`: 全5 smoke tests PASS
