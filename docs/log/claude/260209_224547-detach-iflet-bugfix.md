# Detach if-let Bug Fix

**Date**: 2026-02-09
**Branch**: feat/tmux-adapter

## Problem

`onSessionDetached` handler in `main.swift` had an `if let` bug:

```swift
if let currentMode = config.tmuxSessionModes[session.project],
   currentMode != "ignore" {
```

When `tmuxSessionModes` had no entry for the detached session's project, `if let`
would fail and skip the ignore write-back entirely. While not a critical risk
(layers 1+2 already block task sending after detach), this meant re-attach could
restore the previous mode instead of defaulting to ignore.

## Fix

Replaced `if let` with `?? "ignore"` fallback:

```swift
let currentMode = config.tmuxSessionModes[session.project] ?? "ignore"
if currentMode != "ignore" {
```

Coverage:
- Entry exists + not ignore -> sets to ignore + save
- Entry exists + already ignore -> no-op
- No entry -> defaults to "ignore" -> no-op (correct, default is already ignore)

## Changed Files

- `ClawGate/main.swift:94-95` — `if let` -> `let + ??` pattern

## Verification

- `swift build` OK
- `dev-deploy.sh --skip-test` OK (build + deploy + gateway restart)
