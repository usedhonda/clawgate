# ClawGate Technical Specification

## 1. Overview

ClawGate is a macOS menubar-resident app that bridges local AI agents to native macOS
applications via Accessibility (AX) UI automation. It exposes a localhost-only HTTP API
(SwiftNIO) and supports LINE and tmux (Claude Code) adapters.

- **Server**: SwiftNIO HTTP/1.1 on `127.0.0.1:8765`
- **Platform**: macOS 12+ (SwiftPM, swift-tools-version 5.9)
- **Dependency**: swift-nio 2.67+ (NIOCore, NIOHTTP1, NIOPosix)
- **Signing**: Self-signed cert ("ClawGate Dev") for stable CDHash

---

## 2. Directory Structure

```
ClawGate/
  main.swift                          # AppRuntime, NSApplication entry (.accessory policy)
  Adapters/
    AdapterProtocol.swift             # AdapterProtocol + AdapterRegistry
    LINE/
      LINEAdapter.swift               # LINE AX automation (send, context, messages, conversations)
      LINEInboundWatcher.swift        # AX polling for inbound message detection
      NotificationBannerWatcher.swift # Event-driven banner detection (primary)
      LineSelectors.swift             # UniversalSelector definitions for LINE UI elements
      Detection/
        LineDetectionTypes.swift      # Signal, Decision, StateSnapshot types
        LineDetectionFusionEngine.swift # Multi-signal fusion scoring engine
    Tmux/
      TmuxAdapter.swift               # Claude Code task dispatch via tmux
      TmuxInboundWatcher.swift        # State transition detection + question capture
      CCStatusBarClient.swift         # WebSocket client for cc-status-bar
      TmuxShell.swift                 # tmux CLI wrapper (send-keys, capture-pane)
  Automation/
    AX/
      AXQuery.swift                   # AXUIElement tree traversal, descendant search
      AXActions.swift                 # setValue, press, focus, paste, key events
      AXAppWindow.swift               # App/window resolution helpers
      AXDump.swift                    # Full AX tree dump for debugging
    Selectors/
      SelectorResolver.swift          # Multi-layer scoring: identifier -> text -> permission -> geometry
      UniversalSelector.swift         # Selector definition struct
      GeometryHint.swift              # Spatial filtering (top/bottom/left/right of window)
    Retry/
      RetryPolicy.swift               # Exponential backoff with max attempts
    Vision/
      VisionOCR.swift                 # Screen capture + Vision framework text recognition
  Core/
    BridgeServer/
      BridgeServer.swift              # NIO bootstrap (bind, channel pipeline)
      BridgeRequestHandler.swift      # HTTP routing, blocking offload
      BridgeCore.swift                # Business logic for all endpoints
      BridgeModels.swift              # All Codable request/response structs
      BridgeRuntimeError.swift        # Structured error type -> ErrorPayload
    Config/
      AppConfig.swift                 # ConfigStore (UserDefaults-backed)
    EventBus/
      EventBus.swift                  # In-memory event ring buffer + SSE subscriptions
      RecentSendTracker.swift         # Echo suppression (8s temporal window)
    Logging/
      AppLogger.swift                 # Leveled logger (debug/info/warning/error)
      StepLog.swift                   # Per-step operation log for send flows
  UI/
    MenuBarApp.swift                  # NSMenu, sessions submenu, status
    SettingsView.swift                # SwiftUI settings panel
    QRCodeView.swift                  # QR code display
Tests/
  UnitTests/
    BridgeCoreTests.swift             # Routing, error codes, Origin check, mock adapters
    SelectorResolverTests.swift       # Multi-layer selector scoring
    ChromeFilterTests.swift           # Timestamp/date chrome exclusion
    EventBusTests.swift               # Poll, overflow, subscribe/unsubscribe
    ConfigStoreTests.swift            # Configuration load/save, migration
    RecentSendTrackerTests.swift      # Echo suppression window logic
    RetryPolicyTests.swift            # Backoff calculation
    TmuxOutputParserTests.swift       # Tmux capture-pane output parsing
scripts/
  dev-deploy.sh                       # Build + deploy + plugin sync + smoke test
  smoke-test.sh                       # Quick validation (5 tests)
  integration-test.sh                 # Full API test suite (18 tests)
  release.sh                          # Universal binary build, sign, DMG, notarize
  setup-cert.sh                       # Self-signed certificate setup
extensions/
  openclaw-plugin/                    # OpenClaw channel plugin (JS/ESM)
  vibeterm-telemetry/                 # Location telemetry plugin (JS/ESM)
```

---

## 3. Threading Model

```
┌─────────────────────────────┐
│  NIO EventLoop (1 thread)   │  handles: health, poll, SSE write, response write
│  - NEVER do blocking work   │
└──────────┬──────────────────┘
           │ offload via BlockingWork.queue.async { }
           ▼
┌─────────────────────────────┐
│  BlockingWork.queue          │  serial DispatchQueue (.userInitiated)
│  (com.clawgate.blocking)    │  handles: AX queries, send, doctor
└─────────────────────────────┘
           │ context.eventLoop.execute { writeResponse }
           ▼
      back to NIO EventLoop
```

### Rules
- **health**, **poll**, **SSE**: handled directly on event loop (no blocking calls)
- **AX-dependent endpoints** (send, context, messages, conversations, axdump, doctor): offloaded to `BlockingWork.queue`
- **LINEInboundWatcher**: runs its own timer on BlockingWork.queue (serialized with HTTP handlers)

### Why serial queue?
AX queries on LINE (Qt app) are not thread-safe. `BlockingWork.queue` serializes all
AX access between HTTP request handlers and `LINEInboundWatcher` to prevent concurrent
AXUIElement calls.

---

## 4. Security

ClawGate binds to `127.0.0.1:8765` by default. Optional remote mode binds `0.0.0.0:8765`.
In local mode, token authentication is not required. In remote mode, Bearer auth is required for all endpoints except `/v1/health`.

### CSRF Protection
All `POST` requests are checked for an `Origin` header. If present and non-empty,
the request is rejected with HTTP 403 and error code `browser_origin_rejected`.
This prevents browser-initiated cross-origin requests from reaching the API.

---

## 5. API Reference

Base URL: `http://127.0.0.1:8765`

All responses are `Content-Type: application/json; charset=utf-8`.

### 5.1 Response Envelope

Success:
```json
{ "ok": true, "result": { ... } }
```

Error:
```json
{
  "ok": false,
  "error": {
    "code": "error_code",
    "message": "Human-readable message",
    "retriable": false,
    "failed_step": "step_name",
    "details": "optional details"
  }
}
```

### 5.2 Error Codes

| Code | HTTP | Retriable | Trigger |
|------|------|-----------|---------|
| `method_not_allowed` | 405 | false | Wrong HTTP method for known path |
| `not_found` | 404 | false | Unknown path |
| `invalid_json` | 400 | false | Request body not valid JSON |
| `adapter_not_found` | 400 | false | Unknown adapter name |
| `unsupported_action` | 400 | false | action != "send_message" |
| `invalid_conversation_hint` | 400 | false | Empty conversation_hint |
| `invalid_text` | 400 | false | Empty text |
| `ax_permission_missing` | 400 | false | Accessibility not granted |
| `line_not_running` | 503 | true | LINE app not running |
| `line_window_not_found` | 503 | true | LINE window not accessible |
| `message_input_not_found` | 503 | true | Chat input field not found |
| `browser_origin_rejected` | 403 | false | Origin header present on POST request |
| `axdump_failed` | 503 | true | AX tree dump failed |
| `not_supported` | 400 | false | Adapter doesn't implement method |
| `session_not_found` | 503 | true | No Claude Code session for given project |
| `session_busy` | 503 | true | Session is currently running a task |
| `session_read_only` | 400 | false | Session is in observe mode (read-only) |
| `session_not_allowed` | 400 | false | Session is not enabled (ignore mode) |
| `tmux_target_missing` | 503 | true | Session has no tmux target pane |
| `tmux_command_failed` | 503 | true | tmux CLI command execution failed |
| `forbidden_key` | 400 | false | Blocked key sequence (C-c, C-d, C-z, C-\\) |

### 5.3 Endpoints

---

#### `GET /v1/health`
Returns immediately on event loop.

Response:
```json
{ "ok": true, "version": "0.1.0" }
```

---

#### `GET /v1/config`
Returns immediately on event loop.

Response:
```json
{
  "ok": true,
  "result": {
    "version": "0.1.0",
    "general": {
      "debugLogging": false,
      "includeMessageBodyInLogs": false
    },
    "line": {
      "default_conversation": "",
      "poll_interval_seconds": 2,
      "detection_mode": "hybrid",
      "fusion_threshold": 60,
      "enable_pixel_signal": true,
      "enable_process_signal": false,
      "enable_notification_store_signal": false
    },
    "tmux": {
      "enabled": false,
      "statusBarUrl": "ws://localhost:8080/ws/sessions",
      "sessionModes": {}
    }
  }
}
```

---

#### `GET /v1/doctor`
Offloaded to BlockingWork.queue.

Response:
```json
{
  "ok": true,
  "version": "0.1.0",
  "checks": [
    { "name": "accessibility_permission", "status": "ok", "message": "...", "details": null },
    { "name": "line_running",            "status": "ok", "message": "...", "details": null },
    { "name": "line_window_accessible",  "status": "ok", "message": "...", "details": "..." },
    { "name": "server_port",             "status": "ok", "message": "...", "details": "127.0.0.1:8765" },
    { "name": "screen_recording_permission", "status": "ok", "message": "...", "details": null }
  ],
  "summary": { "total": 5, "passed": 5, "warnings": 0, "errors": 0 },
  "timestamp": "2026-02-06T08:39:28Z"
}
```

Check status values: `"ok"`, `"warning"`, `"error"`.
HTTP status: 200 if no errors, 503 if any error.

---

#### `GET /v1/poll[?since=N]`
Offloaded to BlockingWork.queue.

Response:
```json
{
  "ok": true,
  "events": [
    {
      "id": 1,
      "type": "inbound_message",
      "adapter": "line",
      "payload": { "text": "hello", "conversation_hint": "..." },
      "observed_at": "2026-02-06T12:00:00Z"
    }
  ],
  "next_cursor": 1
}
```

Without `since`: returns all buffered events (max 1000).
With `since=N`: returns events with `id > N`.

---

#### `GET /v1/events`
SSE (Server-Sent Events) stream.

Headers: `Last-Event-ID` (optional, for replay).

Response: `text/event-stream`
```
id: 1
data: {"id":1,"type":"inbound_message","adapter":"line",...}

id: 2
data: {"id":2,"type":"heartbeat","adapter":"system",...}
```

On connect without `Last-Event-ID`: replays last 3 events.
On connect with `Last-Event-ID: N`: replays all events since N.
Then streams new events in real-time.

---

#### `GET /v1/context[?adapter=line]`
Offloaded to BlockingWork.queue. Requires AX permission.

Response:
```json
{
  "ok": true,
  "result": {
    "adapter": "line",
    "conversation_name": "John Doe",
    "has_input_field": true,
    "window_title": "LINE",
    "timestamp": "2026-02-06T12:00:00Z"
  }
}
```

---

#### `GET /v1/messages[?adapter=line&limit=50]`
Offloaded to BlockingWork.queue. Requires AX permission.

Query params: `adapter` (default: "line"), `limit` (default: 50, max: 200).

Response:
```json
{
  "ok": true,
  "result": {
    "adapter": "line",
    "conversation_name": "John Doe",
    "messages": [
      { "text": "hello", "sender": "other", "y_order": 0 },
      { "text": "hi!", "sender": "self", "y_order": 1 }
    ],
    "message_count": 2,
    "timestamp": "2026-02-06T12:00:00Z"
  }
}
```

`sender`: `"self"` | `"other"` | `"unknown"`.
`y_order`: vertical position in chat (0 = topmost visible).

---

#### `GET /v1/conversations[?adapter=line&limit=50]`
Offloaded to BlockingWork.queue. Requires AX permission.

Response:
```json
{
  "ok": true,
  "result": {
    "adapter": "line",
    "conversations": [
      { "name": "John Doe", "y_order": 0, "has_unread": true },
      { "name": "Group Chat", "y_order": 1, "has_unread": false }
    ],
    "count": 2,
    "timestamp": "2026-02-06T12:00:00Z"
  }
}
```

---

#### `GET /v1/axdump[?adapter=line]`
Offloaded to BlockingWork.queue. Requires AX permission.

Returns the raw AX tree of the target app as nested JSON. Used for debugging
selector issues. Response structure: recursive `AXDumpNode` objects.

---

#### `POST /v1/send`
Offloaded to BlockingWork.queue. Requires AX permission.

Request:
```json
{
  "adapter": "line",
  "action": "send_message",
  "payload": {
    "conversation_hint": "John Doe",
    "text": "Hello from ClawGate",
    "enter_to_send": true
  }
}
```

Validation:
- `action` must be `"send_message"` (only supported action)
- `conversation_hint` must be non-empty
- `text` must be non-empty

Response:
```json
{
  "ok": true,
  "result": {
    "adapter": "line",
    "action": "send_message",
    "message_id": "local-uuid",
    "timestamp": "2026-02-06T12:00:00Z"
  }
}
```

---

## 6. Adapter Protocol

```swift
protocol AdapterProtocol {
    var name: String { get }                  // e.g. "line"
    var bundleIdentifier: String { get }      // e.g. "jp.naver.line.mac"
    func sendMessage(payload: SendPayload) throws -> (SendResult, [StepLog])
    func getContext() throws -> ConversationContext
    func getMessages(limit: Int) throws -> MessageList
    func getConversations(limit: Int) throws -> ConversationList
}
```

Default implementations throw `not_supported` for read methods.
`AdapterRegistry` maps adapter name -> instance via dictionary lookup.

Current adapters: `line` (LINEAdapter), `tmux` (TmuxAdapter).

### LINEAdapter

The LINE adapter automates LINE Desktop for Mac (Qt, bundle ID `jp.naver.line.mac`) via AX:

- **sendMessage**: activate LINE -> search conversation by hint -> navigate to chat -> set message text -> send Enter (via `AXUIElementPostKeyboardEvent`)
- **getContext**: Read current conversation name, input field presence, window title
- **getMessages**: Extract visible messages with sender classification (`self`/`other`/`unknown`) and y-order
- **getConversations**: List sidebar conversations with unread status and y-order

### TmuxAdapter

The tmux adapter sends tasks to Claude Code sessions running in tmux panes:

- **Session discovery**: Via `CCStatusBarClient` WebSocket connection to cc-status-bar
- **Mode resolution**: Checks `tmuxSessionModes` config for the target project. Only `auto` and `autonomous` modes allow sending.
- **sendMessage flow**: Resolve session -> validate mode -> `TmuxShell.sendKeys()` to tmux pane
- **Menu selection** (`__cc_select:N`): When text starts with `__cc_select:`, navigates AskUserQuestion menus via Up/Down arrow keys + Enter
- **Read methods**: `getContext`, `getMessages`, `getConversations` all throw `not_supported` (tmux sessions don't have a chat-like read model)

---

## 7. Event System

### EventBus

- In-memory ring buffer, max 1000 events
- Auto-incrementing `Int64` event IDs (monotonic, starting at 1)
- Thread-safe via `NSLock`
- Subscribers receive events via synchronous callback (called after lock release)

### Event Structure
```json
{
  "id": 42,
  "type": "inbound_message",
  "adapter": "line",
  "payload": { "text": "...", "conversation_hint": "..." },
  "observed_at": "2026-02-06T12:00:00Z"
}
```

### Event Types

| Type | Adapter | Source | Description |
|------|---------|--------|-------------|
| `inbound_message` | `line` | NotificationBannerWatcher, LINEInboundWatcher | New message from another user |
| `echo_message` | `line` | LINEInboundWatcher | Self-sent message detected (suppressed as inbound) |
| `inbound_message` | `tmux` | TmuxInboundWatcher | Task completion or question from Claude Code |
| `progress` | `tmux` | TmuxInboundWatcher | Running session output (periodic, 20s interval) |
| `heartbeat` | `system` | EventBus | Periodic keep-alive for SSE connections |

### Echo Suppression

`RecentSendTracker` maintains a temporal window (8 seconds) of recent `send_message` calls:

- `recordSend(conversation, text)`: Called after every successful send
- `isLikelyEcho()`: Returns true if any send was recorded within the 8s window
- Thread-safe via `NSLock`; stale entries purged on each access
- LINE Qt always reports window title as "LINE" (not the conversation name), so matching is adapter-level: any recent send within the window marks detection as likely echo
- Echo events are emitted as `echo_message` type instead of `inbound_message`

### NotificationBannerWatcher (Primary LINE Detection)

Event-driven detection that monitors macOS notification banners from LINE:

- **AXObserver**: Watches `com.apple.notificationcenterui` for `kAXWindowCreatedNotification` events on the main CFRunLoop
- **Fallback polling**: 2-second timer to catch banners missed by the observer (e.g., when notificationcenterui restarts)
- **Text extraction**: Reads sender name and message text from banner AX tree (`AXStaticText` children). Since banners are drawn by Apple's notification center (not LINE's Qt), standard AX APIs work reliably without OCR.
- **Deduplication**: Fingerprint-based (sender + text prefix) with a 10-second window to prevent duplicate events from overlapping observer + polling detection
- **Echo check**: Consults `RecentSendTracker` before emitting
- **Emits**: `inbound_message` events with `confidence=high`, `score=95`

### LINEInboundWatcher (Secondary LINE Detection)

AX polling-based detection that monitors the LINE window directly:

- Polls LINE's visible chat area at a configurable interval (default: 2 seconds)
- Runs on `BlockingWork.queue` (serialized with HTTP handlers)
- Two detection modes controlled by `lineDetectionMode` config:

**Legacy mode** (`lineDetectionMode: "legacy"`):
- First signal wins: either AX row count change or pixel diff triggers emission
- No scoring or threshold evaluation

**Hybrid mode** (`lineDetectionMode: "hybrid"`, default):
- Collects multiple signals and passes them to `LineDetectionFusionEngine`
- Only emits when the fused score meets the configured threshold

### Hybrid Detection / FusionEngine

`LineDetectionFusionEngine` aggregates detection signals using score-based threshold evaluation:

```
Total score = min(100, sum of all signal scores)
Decision: emit if score >= threshold (default: 60)
```

**Signal types and scoring:**

| Signal | Score Range | Trigger |
|--------|-------------|---------|
| `ax_structure` | 58-70 | Row count change = 70 pts; bottom position change only = 58 pts |
| `pixel_diff` | 35-48 | OCR text changed = 48 pts; image hash change only = 35 pts |
| `process` | (placeholder) | Not yet implemented |
| `notification_store` | (placeholder) | Not yet implemented |

**Confidence levels:**

| Score | Confidence |
|-------|------------|
| >= 80 | `high` |
| >= 50 | `medium` |
| < 50 | `low` |

**Design rationale**: A score-based threshold system was chosen over binary detection to allow contextual availability of signals. Not all signals are available at all times (e.g., OCR requires screen recording permission, AX tree may be empty when LINE is backgrounded). The fusion approach provides fast-path emission for high-trust signals while remaining extensible for future signal types.

### Detection Configuration

| Config Key | Default | Description |
|------------|---------|-------------|
| `lineDetectionMode` | `"hybrid"` | `"legacy"` or `"hybrid"` |
| `lineFusionThreshold` | `60` | Score threshold for hybrid mode (1-100) |
| `lineEnablePixelSignal` | `true` | Enable pixel diff / OCR signal |
| `lineEnableProcessSignal` | `false` | Enable process signal (placeholder) |
| `lineEnableNotificationStoreSignal` | `false` | Enable notification store signal (placeholder) |

---

## 8. Tmux Integration

ClawGate includes a tmux adapter for monitoring and interacting with Claude Code sessions running in tmux panes. This enables AI agents (via OpenClaw) to dispatch tasks to Claude Code and receive completion/question notifications.

### CCStatusBarClient

WebSocket client that connects to [cc-status-bar](https://github.com/anthropics/cc-status-bar) at `ws://localhost:8080/ws/sessions` (configurable via `tmuxStatusBarUrl`).

- Tracks all active Claude Code sessions with their state (`running`, `waiting_input`, `stopped`)
- Maintains an in-memory session dictionary keyed by session ID
- Fires `onStateChange(session, oldStatus, newStatus)` callback on state transitions
- Auto-reconnects with exponential backoff (up to 20 attempts)
- Thread-safe via `NSLock`

**CCSession fields:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | String | Unique session identifier |
| `project` | String | Project directory name |
| `status` | String | `"running"`, `"waiting_input"`, or `"stopped"` |
| `tmuxSession` | String? | tmux session name |
| `tmuxWindow` | String? | tmux window index |
| `tmuxPane` | String? | tmux pane index |
| `isAttached` | Bool | Whether the tmux session is currently attached |
| `attentionLevel` | Int | 0=green, 1=yellow, 2=red |
| `waitingReason` | String? | `"permission_prompt"`, `"stop"`, or nil |

### TmuxShell

Thin synchronous wrapper around the `tmux` CLI. All methods should be called from `BlockingWork.queue`.

- `sendKeys(target:text:enter:)`: Send literal text to a tmux pane, optionally followed by Enter
- `capturePane(target:lines:)`: Capture the visible content of a tmux pane (last N lines)
- `listSessions()`: List all tmux sessions
- `sendSpecialKey(target:key:)`: Send a non-literal key (e.g., "Up", "Down", "Enter")

**Forbidden keys**: `C-c`, `C-d`, `C-z`, `C-\` are blocked to prevent exiting Claude Code to a raw shell. Attempts to send these keys return error code `forbidden_key`.

### TmuxInboundWatcher

Monitors Claude Code session state transitions and emits events:

- **Completion detection**: When a session transitions from `running` to `waiting_input` (and `waitingReason` is not `permission_prompt`), captures the pane output and emits an `inbound_message` event with `source: "completion"`
- **Question detection**: Analyzes captured pane output for AskUserQuestion patterns (option markers like `○`, `●`, question marks). Emits with `source: "question"` and structured fields: `question_text`, `options` (JSON array), `selected_index`, `question_id`
- **Permission auto-approval**: When `waitingReason == "permission_prompt"` and mode is `auto` or `autonomous`, sends "y" + Enter to auto-approve
- **Progress emission**: A 20-second periodic timer captures pane output from running sessions and emits `progress` events (only when content changes, tracked via hash)
- **200ms render delay**: Waits briefly after state change for UI to finish rendering before capture

### Session Modes

Per-project session modes are stored in `tmuxSessionModes` config (project name -> mode string):

| Mode | Send Tasks | Receive Events | Auto-Approve | Description |
|------|-----------|---------------|--------------|-------------|
| `ignore` (default) | No | No | No | Session detected but not monitored |
| `observe` | No | Yes | No | Completion notifications only, task dispatch blocked (`session_read_only`) |
| `auto` | Yes | Yes | Yes | Generic "continue" prompts, permission auto-approval |
| `autonomous` | Yes | Yes | Yes | AI-designed follow-up tasks with full context |

Mode is resolved by looking up the project name in the `tmuxSessionModes` dictionary. Projects not in the dictionary default to `ignore`.

### Menu Bar Sessions Submenu

The menu bar displays a "Sessions" submenu showing all tracked Claude Code sessions:

- Each session shows project name, status, and current mode icon
- Mode icons: `bolt` (autonomous), `gearshape` (auto), `eye` (observe), `minus` (ignore)
- Click to cycle through modes: ignore -> observe -> auto -> autonomous -> ignore

---

## 9. Selector System

UI elements are located using a multi-layer scoring system:

1. **L1 - Identifier match**: AXIdentifier exact/contains match (highest confidence)
2. **L2 - Text hint**: AXTitle/AXDescription/AXValue text matching
3. **L3 - Permission filter**: Requires settable attributes or specific AX actions
4. **L4 - Geometry filter**: Spatial position within window (top/bottom/left/right)

`SelectorResolver` scores all candidates and returns the best match.
`UniversalSelector` defines the criteria per UI element.
`LineSelectors` contains LINE-specific selector definitions.

---

## 10. Build & Deploy

### One-shot deploy (preferred)
```bash
./scripts/dev-deploy.sh                  # Build + deploy + plugin sync + smoke test
./scripts/dev-deploy.sh --skip-plugin    # ClawGate only (no OpenClaw)
./scripts/dev-deploy.sh --skip-test      # Deploy without smoke test
```

### Manual debug build
```bash
swift build
cp .build/debug/ClawGate ClawGate.app/Contents/MacOS/ClawGate
codesign --force --deep --options runtime --entitlements ClawGate.entitlements --sign "ClawGate Dev" ClawGate.app
```

**Important**: Always sign with `--sign "ClawGate Dev"` (self-signed cert), not `--sign -` (ad-hoc). Ad-hoc signing produces a different CDHash each time, which invalidates the TCC Accessibility permission entry. The "ClawGate Dev" cert produces a stable CDHash so permission persists across rebuilds. Run `./scripts/setup-cert.sh` for first-time certificate setup.

### Release build (native arch)
```bash
swift build -c release
```

### Release build (universal, requires Xcode)
```bash
swift build -c release --arch arm64 --arch x86_64
```

### Unit tests (requires Xcode, not just CommandLineTools)
```bash
swift test
```

### Testing
```bash
./scripts/smoke-test.sh                  # Quick validation (5 tests, ~5s)
./scripts/integration-test.sh            # Full API test suite (18 tests)
```

### Release pipeline (`scripts/release.sh`)
1. `swift test`
2. Universal binary build
3. App bundle update
4. Code signing (Developer ID)
5. DMG creation (`hdiutil`)
6. Notarization (`xcrun notarytool`)
7. Stapling (`xcrun stapler`)
8. Optional: GitHub Release (`--publish`)

### CI

GitHub Actions CI (`.github/workflows/ci.yml`) runs on push to `main` and on pull requests:
- `swift build` (macOS)
- Unit tests (when Xcode is available)

---

## 11. macOS Permissions & Constraints

| Permission | Required For | How to Grant |
|-----------|-------------|--------------|
| Accessibility | All AX endpoints (context, messages, conversations, send, axdump, doctor window check) | System Settings > Privacy & Security > Accessibility > ClawGate ON |
| Screen Recording | Vision OCR for inbound message text extraction | System Settings > Privacy > Screen Recording > ClawGate ON |

### Constraints
- **Accessibility**: Cannot be granted programmatically (macOS security policy)
- **LINE (Qt)**: AX tree is only available when LINE window is in foreground.
  Background windows return empty/partial trees.
- **Screen lock**: AX automation requires an active user session with display awake.

---

## 12. Integration Test Coverage

Integration tests: `./scripts/integration-test.sh` (18 tests)

| Phase | Tests | What |
|-------|-------|------|
| Phase 0: Health | 1 | Health check |
| Phase 1: Error Handling | 2 | Wrong method, not found |
| Phase 2: Doctor | 3 | Doctor response, LINE check, AX check |
| Phase 3: Poll & Events | 3 | Poll, poll with since, SSE connection |
| Phase 4: AX endpoints | 4 | Context, messages, conversations, axdump (skip if no AX) |
| Phase 5: Send API | 4 | Send (skip if no AX), invalid adapter, invalid JSON, unsupported action |
| Phase 6: Security | 1 | CSRF Origin rejection on /v1/send |

Tests auto-skip AX-dependent cases when Accessibility permission is not granted.

### Unit Tests

8 test files in `Tests/UnitTests/`:

| File | Coverage |
|------|----------|
| `BridgeCoreTests.swift` | Routing, error codes, Origin check, mock adapters |
| `SelectorResolverTests.swift` | Multi-layer selector scoring |
| `ChromeFilterTests.swift` | Timestamp/date chrome exclusion |
| `EventBusTests.swift` | Poll, overflow, subscribe/unsubscribe |
| `ConfigStoreTests.swift` | Configuration load/save, legacy migration |
| `RecentSendTrackerTests.swift` | Echo suppression window logic |
| `RetryPolicyTests.swift` | Backoff calculation |
| `TmuxOutputParserTests.swift` | Tmux capture-pane output parsing |

## 13. Vibeterm Telemetry Plugin

OpenClaw plugin (`extensions/vibeterm-telemetry/`) that receives iOS background location
updates and writes them to daily diary files.

### Endpoint

`POST /api/telemetry` (via OpenClaw gateway :18789)

- Auth: `Authorization: Bearer {gateway-token}`
- Body: `{ "samples": [{ "id", "lat", "lon", "accuracy", "timestamp" }] }`
- Response: `{ "received": N, "nextMinIntervalSec": 60 }`

### Storage

1. **In-memory**: UUID-based dedup store (`store.js`)
2. **Diary**: `~/.openclaw/workspace/memory/YYYY-MM-DD.md`
   - Format: `📍 HH:MM - lat, lon (accuracy Xm)`
   - Throttle: 200m movement or 30min elapsed

### Relation to BodyForAgent

| Layer | Scope | When |
|-------|-------|------|
| BodyForAgent | Real-time coordinate injection per message | Message arrives while moving |
| Diary | Persistent location history | Session start, movement tracking |
