# Activity Stats Implementation

**Date**: 2026-02-10
**Task**: Implement daily activity stats tracking for ClawGate

## Changes

### New Files
- `ClawGate/Core/Stats/StatsCollector.swift` — Core stats engine
  - `DayStats` struct (Codable) with 7 metrics + first/last event timestamps
  - Thread-safe (NSLock), in-memory daily counters + JSON persistence
  - Auto-prune entries older than 90 days
  - `handleEvent()` classifies EventBus events (inbound_message, echo_message)
  - `increment()` called directly for outbound sends and API requests
- `Tests/UnitTests/StatsCollectorTests.swift` — 11 unit tests

### Modified Files
- `ClawGate/main.swift:5-6` — Added `statsCollector` property to AppRuntime
- `ClawGate/main.swift:25-30` — Pass statsCollector to BridgeCore
- `ClawGate/main.swift:67-75` — Subscribe EventBus for stats + menu refresh
- `ClawGate/main.swift:118` — Pass statsCollector to MenuBarAppDelegate
- `ClawGate/Core/BridgeServer/BridgeCore.swift:6-7` — Added statsCollector property
- `ClawGate/Core/BridgeServer/BridgeCore.swift:115` — Track send success
- `ClawGate/Core/BridgeServer/BridgeCore.swift:228-240` — Added `stats(days:)` method
- `ClawGate/Core/BridgeServer/BridgeRequestHandler.swift:22` — Added /v1/stats route
- `ClawGate/Core/BridgeServer/BridgeRequestHandler.swift:83-87` — API request counting
- `ClawGate/Core/BridgeServer/BridgeRequestHandler.swift:90-95` — Stats handler (non-blocking)
- `ClawGate/Core/BridgeServer/BridgeModels.swift:205-222` — StatsResult, DayStatsEntry models
- `ClawGate/UI/MenuBarApp.swift:10-15` — Added todayStatsItem and statsCollector
- `ClawGate/UI/MenuBarApp.swift:24-29` — Stats menu item at top of menu
- `ClawGate/UI/MenuBarApp.swift:215-223` — `refreshTodayStats()` method
- `Tests/UnitTests/BridgeCoreTests.swift:214,227` — Updated BridgeCore init calls

## Tracked Metrics
| Key | Source |
|-----|--------|
| `line_sent` | BridgeCore.send() success (adapter=line) |
| `line_received` | EventBus inbound_message adapter=line |
| `line_echo` | EventBus echo_message adapter=line |
| `tmux_sent` | BridgeCore.send() success (adapter=tmux) |
| `tmux_completion` | EventBus inbound_message adapter=tmux source=completion |
| `tmux_question` | EventBus inbound_message adapter=tmux source=question |
| `api_requests` | All HTTP requests after CSRF check |

## Storage
- File: `~/Library/Application Support/ClawGate/stats.json`
- Daily buckets keyed by YYYY-MM-DD (local timezone)
- Auto-prune > 90 days

## API
- `GET /v1/stats[?days=7]` — Non-blocking (in-memory read)
- Returns `today` (live counters) + `history` (previous days, reverse chronological)

## Menu Bar
- "Today: N sent, M received" at top of menu (disabled, info-only)
- Appends " · N tasks" if tmux has activity
- Refreshes on every EventBus event

## Verification
- swift build: OK
- dev-deploy.sh: OK (5/5 smoke tests pass)
- /v1/stats endpoint: Returns correct JSON structure
- stats.json: Created at correct path
- api_requests counter: Incrementing correctly (367 after smoke tests)
