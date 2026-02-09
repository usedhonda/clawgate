# Tmux Autonomous Mode Improvements

**Date**: 2026-02-09
**Branch**: feat/tmux-adapter

## Changes

### 1. Removed task chain limit (`gateway.js`)
- Deleted `MAX_CONSECUTIVE_TASKS`, `consecutiveTaskCount` Map, `resetTaskChain()` function
- Removed all chain counter logic from `tryExtractAndSendTask()`, `handleInboundMessage()`, `handleTmuxCompletion()`
- Removed `Chain: X/5 (Y remaining)` from AUTONOMOUS MODE prompt
- Added `[OpenClaw Agent]` prefix to tasks sent to Claude Code via tmux

### 2. Added `sendSpecialKey()` to TmuxShell (`TmuxShell.swift`)
- New method for sending non-literal keys: Up, Down, BTab, Escape, Enter, y, etc.
- Security: `forbiddenKeys` set blocks C-c, C-d, C-z, C-\ (would exit CC to raw shell)
- Throws `BridgeRuntimeError(code: "forbidden_key")` on violation

### 3. Permission prompt auto-approval (`TmuxInboundWatcher.swift`)
- Detects `waitingReason == "permission_prompt"` from cc-status-bar
- In autonomous mode: sends `y` via `TmuxShell.sendSpecialKey()` to auto-approve
- Guards completion detection: `waitingReason == "permission_prompt"` transitions are NOT treated as task completions
- observe/ignore modes: permission prompts are ignored (user must handle manually)

## Files Changed

| File | Changes |
|------|---------|
| `extensions/openclaw-plugin/src/gateway.js:142-190` | Chain limit removal + [OpenClaw Agent] prefix |
| `ClawGate/Adapters/Tmux/TmuxShell.swift:40-57` | `sendSpecialKey()` with forbidden key guard |
| `ClawGate/Adapters/Tmux/TmuxInboundWatcher.swift:32-72` | Permission auto-approval + completion guard |

## Verification

- Build: OK
- Smoke test: S1-S4 PASS (S5 passed after gateway restart delay)
- OpenClaw doctor: 14/14 PASS
