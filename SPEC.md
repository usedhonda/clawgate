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
    Security/
      BridgeTokenManager.swift        # In-memory token cache (Keychain for persistence only)
      KeychainStore.swift             # SecItemAdd/Update/CopyMatching wrapper
      PairingCodeManager.swift        # One-time 6-digit code with 120s TTL
  UI/
    MenuBarApp.swift                  # NSMenu, pairing code display, status
    SettingsView.swift                # SwiftUI settings panel
Tests/
  UnitTests/
    BridgeCoreTests.swift             # 25 tests: routing, auth, error codes, mock adapters
    SelectorResolverTests.swift       # 13 tests: multi-layer selector scoring
    ChromeFilterTests.swift           # 9 tests: timestamp/date chrome exclusion
    EventBusTests.swift               # 4 tests: poll, overflow, subscribe/unsubscribe
scripts/
  integration-test.sh                # 24 automated API tests with auto-pairing
  release.sh                          # Universal binary build, sign, DMG, notarize
```

---

## 3. Threading Model

```
┌─────────────────────────────┐
│  NIO EventLoop (1 thread)   │  handles: health, pair/generate, SSE write, response write
│  - NEVER do blocking work   │
└──────────┬──────────────────┘
           │ offload via BlockingWork.queue.async { }
           ▼
┌─────────────────────────────┐
│  BlockingWork.queue          │  serial DispatchQueue (.userInitiated)
│  (com.clawgate.blocking)    │  handles: auth check, AX queries, Keychain write, send
└─────────────────────────────┘
           │ context.eventLoop.execute { writeResponse }
           ▼
      back to NIO EventLoop
```

### Rules
- **health** and **pair/generate**: handled directly on event loop (no blocking calls)
- **All auth-protected endpoints**: offloaded to `BlockingWork.queue`
- **SSE**: auth check on BlockingWork, then SSE streaming on event loop
- **LINEInboundWatcher**: runs its own timer on BlockingWork.queue (serialized with HTTP handlers)
- **Token validation**: uses in-memory cache only (never calls Keychain)

### Why serial queue?
AX queries on LINE (Qt app) are not thread-safe. `BlockingWork.queue` serializes all
AX access between HTTP request handlers and `LINEInboundWatcher` to prevent concurrent
AXUIElement calls.

---

## 4. Authentication

### Token Lifecycle

```
App start
  └─ cachedToken = nil (no Keychain read at init)

POST /v1/pair/generate
  └─ PairingCodeManager.generateCode() -> 6-digit code (120s TTL, one-time use)

POST /v1/pair/request { code, client_name }
  └─ validate code -> BridgeTokenManager.regenerateToken()
     └─ generates UUID (hex, 32 chars), stores in cachedToken + Keychain
     └─ returns token to client

Subsequent requests: X-Bridge-Token header
  └─ BridgeTokenManager.validate() -> compares against cachedToken (no Keychain read)

App restart
  └─ cachedToken = nil -> client must re-pair via pair/generate + pair/request
```

### CSRF Protection
- `POST /v1/pair/request` rejects requests with non-empty `Origin` header
  (error code: `browser_origin_rejected`, HTTP 403)

### Keychain Details
- Service: `com.clawgate.local`
- Account: `bridge.token`
- Keychain is write-only at runtime (never read after init)
- Ad-hoc signing causes `SecItemCopyMatching` to trigger a blocking macOS dialog

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
| `unauthorized` | 401 | false | Missing or invalid X-Bridge-Token |
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
| `invalid_pairing_code` | 401 | true | Wrong/expired/used pairing code |
| `browser_origin_rejected` | 403 | false | Origin header present on pair/request |
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

#### `POST /v1/pair/generate`
No auth. Returns immediately on event loop.

Request body: none (or empty)

Response:
```json
{
  "ok": true,
  "result": {
    "code": "531540",
    "expires_in": 120
  }
}
```

Generates a 6-digit one-time code valid for 120 seconds.
Invalidates any previously generated code.

---

#### `POST /v1/pair/request`
No auth. Offloaded to BlockingWork.queue (Keychain write).

Request:
```json
{
  "code": "531540",
  "client_name": "my-tool"
}
```

Response:
```json
{
  "ok": true,
  "result": {
    "token": "03C99294A82A47D2887FC12A6347960D",
    "expires_at": null
  }
}
```

`client_name` is optional (logged only). Token does not expire (valid until next pairing
or app restart).

---

#### `GET /v1/doctor`
Auth required. Offloaded to BlockingWork.queue.

Response:
```json
{
  "ok": true,
  "version": "0.1.0",
  "checks": [
    { "name": "accessibility_permission", "status": "ok", "message": "...", "details": null },
    { "name": "token_configured",        "status": "ok", "message": "...", "details": null },
    { "name": "line_running",            "status": "ok", "message": "...", "details": null },
    { "name": "line_window_accessible",  "status": "ok", "message": "...", "details": "..." },
    { "name": "server_port",             "status": "ok", "message": "...", "details": "127.0.0.1:8765" }
  ],
  "summary": { "total": 5, "passed": 5, "warnings": 0, "errors": 0 },
  "timestamp": "2026-02-06T08:39:28Z"
}
```

Check status values: `"ok"`, `"warning"`, `"error"`.
HTTP status: 200 if no errors, 503 if any error.

---

#### `GET /v1/poll[?since=N]`
Auth required. Offloaded to BlockingWork.queue.

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
Auth required. SSE (Server-Sent Events) stream.

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
Auth required. Offloaded to BlockingWork.queue. Requires AX permission.

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
Auth required. Offloaded to BlockingWork.queue. Requires AX permission.

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
Auth required. Offloaded to BlockingWork.queue. Requires AX permission.

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
Auth required. Offloaded to BlockingWork.queue. Requires AX permission.

Returns the raw AX tree of the target app as nested JSON. Used for debugging
selector issues. Response structure: recursive `AXDumpNode` objects.

---

#### `POST /v1/send`
Auth required. Offloaded to BlockingWork.queue. Requires AX permission.

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

## 8. Pairing Code System

- 6-digit numeric code (`000000`-`999999`)
- TTL: 120 seconds from generation
- One-time use: consumed on successful `pair/request`
- Only one active code at a time (generating a new code invalidates the previous)
- Thread-safe via `NSLock`

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
./scripts/integration-test.sh            # auto-pairs, 24 tests
./scripts/integration-test.sh --skip-setup  # uses TOKEN env var
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

## 11. macOS Permissions & Constraints

| Permission | Required For | How to Grant |
|-----------|-------------|--------------|
| Accessibility | All AX endpoints (context, messages, conversations, send, axdump, doctor window check) | System Settings > Privacy & Security > Accessibility > ClawGate ON |
| Keychain | Token persistence (write-only, non-blocking) | Automatic on ad-hoc sign (may prompt once) |

### Constraints
- **Accessibility**: Cannot be granted programmatically (macOS security policy)
- **Ad-hoc signing**: `SecItemCopyMatching` triggers a blocking Keychain dialog.
  Mitigated by in-memory token cache (no Keychain reads at runtime).
- **LINE (Qt)**: AX tree is only available when LINE window is in foreground.
  Background windows return empty/partial trees.
- **Screen lock**: AX automation requires an active user session with display awake.
- **Token non-persistence**: Token is lost on app restart. Re-pairing is trivial via
  `pair/generate` + `pair/request` (no GUI needed).

---

## 12. Integration Test Coverage

24 tests across 6 phases:

| Phase | Tests | What |
|-------|-------|------|
| Phase 0: Health & Pairing | 3 | health, pair/generate, pair/request |
| Phase 1: Auth & Errors | 5 | invalid token, no token, wrong method, not found, bad pairing code |
| Phase 2: Doctor | 4 | doctor response, token check, LINE check, AX check |
| Phase 3: Poll & Events | 3 | poll, poll with since, SSE connection |
| Phase 4: AX endpoints | 4 | context, messages, conversations, axdump (skip if no AX) |
| Phase 5: Send API | 4 | send (skip if no AX), invalid adapter, invalid JSON, unsupported action |
| Phase 6: Security | 1 | CSRF Origin rejection |

Tests auto-skip AX-dependent cases when Accessibility permission is not granted.
