# Fix: TmuxAdapter cc-status-bar field mismatches

**Date**: 2026-02-09
**Branch**: feat/tmux-adapter

## Problem

`/v1/conversations?adapter=tmux` returned empty array despite 4 tmux sessions running
and cc-status-bar active. Root cause: field names in CCStatusBarClient did not match
the actual cc-status-bar WebSocket API.

## Root Causes

### 1. tmux binary path
- Code: `/opt/homebrew/bin/tmux`
- Actual: `/usr/local/bin/tmux`

### 2. Field name mismatches

| Field | cc-status-bar API | Old code |
|-------|------------------|----------|
| status value | `"waiting_input"` | `"waitingInput"` |
| tmux info | nested `tmux: { session, window, pane }` | flat `tmuxSession, tmuxWindow, tmuxPane` |
| session.removed ID key | `"session_id"` | `"sessionId"` |

## Changes

| File | Change |
|------|--------|
| `TmuxShell.swift:7` | tmuxPath -> `/usr/local/bin/tmux` |
| `CCStatusBarClient.swift:221-235` | parseSession: nested tmux object extraction |
| `CCStatusBarClient.swift:206` | `session.removed`: `"session_id"` key |
| `TmuxAdapter.swift:72,84,118,177` | All `"waitingInput"` -> `"waiting_input"` |
| `TmuxInboundWatcher.swift:35` | `"waitingInput"` -> `"waiting_input"` |
| `MenuBarApp.swift:131` | `"waitingInput"` -> `"waiting_input"` |

## Verification

- Build: OK
- Smoke test: 5/5 PASS
- `/v1/conversations?adapter=tmux`: 8 sessions detected (4 projects x 2 sessions each)
- `/v1/context?adapter=tmux`: `has_input_field: true`, sessions visible
