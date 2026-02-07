# sendEnter カスケード戦略 v3 実装

## 指示
LINE への Enter 送信が全手段で失敗する問題に対し、三者議論 + Codex 分析に基づく多層戦略を実装。

## 根本原因
macOS の入力パイプライン (WindowServer/TSM/IME) で合成キーボードイベントが Qt の編集コンポーネントまで到達しない。
CGEvent マウスクリックは届く（マウスとキーボードで経路が異なる）が、CGEvent キーボードは届かない。

## 変更内容

### AXActions.swift
- `sendEnter()` -> `sendEnter(pid: pid_t)` に変更
- 3段階カスケード実装:
  1. `AXUIElementPostKeyboardEvent` — PID に直接キーを送信、WindowServer/TSM バイパス
  2. CGEvent nil source + `.cghidEventTap` — 物理キーボード模倣
  3. CGEvent session tap — 既存フォールバック
- `AXUIElementPostKeyboardEvent` は Swift で unavailable (deprecated 10.9) のため `dlsym` で動的ロード

### LINEAdapter.swift
- `open_conversation` (L128): `sendEnter(pid: app.processIdentifier)`
- `send_message` (L200): `sendEnter(pid: app.processIdentifier)`

### CLAUDE.md
- カスケード戦略と dlsym パターンの注意事項を追記

## テスト結果
- `swift build` 成功（エラーなし）
- Integration test: 18 PASS / 0 FAIL / 6 SKIP
- SKIP = AX 権限未許可（GUI 手動操作が必要）
- AX 権限許可後に送信テストで Enter 到達を目視確認が必要

## 課題
- AX 権限許可は GUI 操作が必須（自動化不可）
- Strategy 1 (AXUIElementPostKeyboardEvent) が Qt LINE で有効かは実機テストで確認要
