# Detach Auto-Ignore Implementation

## Summary
tmux session detach 時に自動で ignore モードに変更し、_sessions リストから除外する安全機能を実装。

## Changes

### CCStatusBarClient.swift
- `onSessionDetached` コールバック追加
- `sessions.list`: detached セッションを `_sessions` に追加しない
- `session.updated`: detach 検出時に `_sessions` から除外 + `onSessionDetached` コールバック発火
- `session.added`: detached セッションを追加しない
- `allSessions()` / `session(forProject:)` の既存 `isAttached` フィルタは防御的に残す

### main.swift
- `startTmuxSubsystem()`: `onSessionDetached` ハンドラ追加 — detach 時に configStore の mode を `ignore` に変更
- `stopServer()`: `onSessionDetached = nil` でコールバック解除

## Design Decisions
- 再 attach 時はユーザーが手動でモードを戻す（安全設計）
- TmuxInboundWatcher は変更不要（上流で detached セッションがフィルタされるため）
- TmuxAdapter.sendMessage() も既に isAttached フィルタで保護済み

## Verification
- `swift build` -> OK
- `dev-deploy.sh` -> S1-S4 PASS, S5 は Gateway 未登録で FAIL（既存環境問題）
