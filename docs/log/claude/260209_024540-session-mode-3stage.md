# Session Mode 3-Stage Implementation

## Date: 2026-02-09

## Task
Implement 3-stage session mode (ignore/observe/autonomous) for tmux sessions,
replacing the binary allowed/not-allowed model.

## Changes

### AppConfig.swift
- `tmuxAllowedSessions: [String]` -> `tmuxSessionModes: [String: String]`
- Migration: legacy `tmuxAllowedSessions` entries converted to "autonomous"
- New UserDefaults key: `clawgate.tmuxSessionModes`

### BridgeModels.swift
- `ConfigTmuxSection.allowedSessions` -> `ConfigTmuxSection.sessionModes`

### BridgeCore.swift
- `config()` uses `sessionModes` instead of `allowedSessions`

### TmuxAdapter.swift
- Added `sessionMode(for:)` and `activeSessions()` helpers
- `sendMessage`: Only "autonomous" mode can send; "observe" returns `session_read_only`
- `getContext`: `hasInputField` true only for autonomous sessions
- `getMessages`: Shows observe + autonomous sessions
- `getConversations`: Shows observe + autonomous sessions (ignore hidden)

### TmuxInboundWatcher.swift
- `handleStateChange`: Checks mode instead of allowed set; skips "ignore"
- Event payload includes `"mode"` field for OpenClaw plugin

### MenuBarApp.swift
- Click cycles: ignore -> observe -> autonomous -> ignore
- Display: `{statusIcon} {project}  {modeIcon}`
- Mode icons: observe=eye, autonomous=lightning, ignore=minus
- Ignore sessions shown with neutral circle icon
- Added `allCCSessions()` to AppRuntime for menu refresh

### gateway.js (OpenClaw plugin)
- `handleTmuxCompletion` reads `mode` from event payload
- Observe mode: Prefixes body with `[OBSERVE MODE - Report only...]`
- Autonomous mode: Standard behavior
- `_tmuxMode` field added to MsgContext

## Verification
- Build: OK
- Smoke test: 5/5 PASS
- Config API: `sessionModes` returned correctly
- OpenClaw: doctor OK + polling started
