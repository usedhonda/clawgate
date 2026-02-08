# ClawGate Technical Specification

## 1. Overview

ClawGate is a macOS menubar-resident app that bridges local AI agents to native macOS
applications via Accessibility (AX) UI automation. It exposes a localhost-only HTTP API
(SwiftNIO) and currently supports LINE as the first adapter target.

- **Server**: SwiftNIO HTTP/1.1 on `127.0.0.1:8765`
- **Platform**: macOS 12+ (SwiftPM, swift-tools-version 5.9)
- **Dependency**: swift-nio 2.67+ (NIOCore, NIOHTTP1, NIOPosix)
- **Signing**: Ad-hoc (no Developer ID cert on this machine)

---

## 2. Directory Structure

```
ClawGate/
  main.swift                          # AppRuntime, NSApplication entry (.accessory policy)
  Adapters/
    AdapterProtocol.swift             # AdapterProtocol + AdapterRegistry
    LINE/
      LINEAdapter.swift               # LINE AX automation (send, context, messages, conversations)
      LINEInboundWatcher.swift        # Background AX poller for inbound message detection
      LineSelectors.swift             # UniversalSelector definitions for LINE UI elements
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
  Core/
    BridgeServer/
      BridgeServer.swift              # NIO bootstrap (bind, channel pipeline)
      BridgeRequestHandler.swift      # HTTP routing, auth, blocking offload
      BridgeCore.swift                # Business logic for all endpoints
      BridgeModels.swift              # All Codable request/response structs
      BridgeRuntimeError.swift        # Structured error type -> ErrorPayload
    Config/
      AppConfig.swift                 # ConfigStore (UserDefaults-backed)
    EventBus/
      EventBus.swift                  # In-memory event ring buffer + SSE subscriptions
    Logging/
      AppLogger.swift                 # Leveled logger (debug/info/warning/error)
      StepLog.swift                   # Per-step operation log for send flows
  UI/
    MenuBarApp.swift                  # NSMenu, QR code, status
    SettingsView.swift                # SwiftUI settings panel
Tests/
  UnitTests/
    BridgeCoreTests.swift             # Unit tests: routing, error codes, Origin check, mock adapters
    SelectorResolverTests.swift       # 13 tests: multi-layer selector scoring
    ChromeFilterTests.swift           # 9 tests: timestamp/date chrome exclusion
    EventBusTests.swift               # 4 tests: poll, overflow, subscribe/unsubscribe
scripts/
  integration-test.sh                # Automated API tests (no auth required)
  release.sh                          # Universal binary build, sign, DMG, notarize
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

ClawGate binds exclusively to `127.0.0.1:8765` — no external access is possible.
No token authentication is required. All endpoints are open to localhost callers.

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

### 5.3 Endpoints

---

#### `GET /v1/health`
No auth. Returns immediately on event loop.

Response:
```json
{ "ok": true, "version": "0.1.0" }
```

---

#### `GET /v1/doctor`
No auth. Offloaded to BlockingWork.queue.

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
No auth. Offloaded to BlockingWork.queue.

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
No auth. SSE (Server-Sent Events) stream.

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
No auth. Offloaded to BlockingWork.queue. Requires AX permission.

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
No auth. Offloaded to BlockingWork.queue. Requires AX permission.

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
No auth. Offloaded to BlockingWork.queue. Requires AX permission.

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
No auth. Offloaded to BlockingWork.queue. Requires AX permission.

Returns the raw AX tree of the target app as nested JSON. Used for debugging
selector issues. Response structure: recursive `AXDumpNode` objects.

---

#### `POST /v1/send`
No auth. Offloaded to BlockingWork.queue. Requires AX permission.

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

Current adapters: `line` (LINEAdapter).

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
- `inbound_message`: New message detected by LINEInboundWatcher
- `heartbeat`: Periodic keep-alive (for SSE connections)

### LINEInboundWatcher
- Polls LINE's visible messages via AX at a configurable interval
- Computes hash-based diff to detect new messages
- Emits `inbound_message` events to EventBus
- Runs on `BlockingWork.queue` (serialized with HTTP handlers)

---

## 8. Selector System

UI elements are located using a multi-layer scoring system:

1. **L1 - Identifier match**: AXIdentifier exact/contains match (highest confidence)
2. **L2 - Text hint**: AXTitle/AXDescription/AXValue text matching
3. **L3 - Permission filter**: Requires settable attributes or specific AX actions
4. **L4 - Geometry filter**: Spatial position within window (top/bottom/left/right)

`SelectorResolver` scores all candidates and returns the best match.
`UniversalSelector` defines the criteria per UI element.
`LineSelectors` contains LINE-specific selector definitions.

---

## 9. Build & Deploy

### Debug build
```bash
swift build
cp .build/debug/ClawGate ClawGate.app/Contents/MacOS/ClawGate
codesign --force --deep --options runtime --entitlements ClawGate.entitlements --sign - ClawGate.app
```

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

### Integration tests
```bash
./scripts/integration-test.sh            # no auth required
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

---

## 10. macOS Permissions & Constraints

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

## 11. Integration Test Coverage

| Phase | Tests | What |
|-------|-------|------|
| Phase 0: Health | 1 | health check |
| Phase 1: Error Handling | 2 | wrong method, not found |
| Phase 2: Doctor | 3 | doctor response, LINE check, AX check |
| Phase 3: Poll & Events | 3 | poll, poll with since, SSE connection |
| Phase 4: AX endpoints | 4 | context, messages, conversations, axdump (skip if no AX) |
| Phase 5: Send API | 4 | send (skip if no AX), invalid adapter, invalid JSON, unsupported action |
| Phase 6: Security | 1 | CSRF Origin rejection on /v1/send |

Tests auto-skip AX-dependent cases when Accessibility permission is not granted.

## 12. Vibeterm Telemetry Plugin

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
