# SPEC-messaging.md -- Communication & Messaging Specification

> Last updated: 2026-02-19
> Source of truth: Swift source under `ClawGate/` + JS plugin under `extensions/openclaw-plugin/src/`

---

## 1. Architecture Overview

### Topology

```
Host A (Server / macmini)                   Host B (Client / local)
+-------------------------------+           +-------------------------------+
| ClawGate.app                  |           | ClawGate.app                  |
|  BridgeServer (SwiftNIO:8765) |           |  BridgeServer (SwiftNIO:8765) |
|  EventBus (ring buffer 1000)  |           |  EventBus (ring buffer 1000)  |
|  FederationServer (WS /federation)|<------|  FederationClient (WS)        |
|  LINEInboundWatcher           |           |  TmuxInboundWatcher           |
|  TmuxInboundWatcher           |           |  CCStatusBarClient            |
|  CCStatusBarClient            |           +-------------------------------+
+-------------------------------+
        ^                                            ^
        | HTTP poll                                  | HTTP poll
+-------------------------------+           +-------------------------------+
| OpenClaw Gateway (macmini)    |           | (no gateway on Host B)        |
|  gateway.js  (poll + dispatch)|           +-------------------------------+
|  outbound.js (sendText)       |
|  context-reader.js            |
|  context-cache.js             |
|  shared-state.js              |
+-------------------------------+
```

### Component Summary

| Component | Layer | Location | Role |
|-----------|-------|----------|------|
| BridgeServer | Swift | `ClawGate/Core/BridgeServer/` | SwiftNIO HTTP server on port 8765 |
| BridgeCore | Swift | `BridgeServer/BridgeCore.swift` | Request routing, auth, send logic, federation forwarding |
| BridgeRequestHandler | Swift | `BridgeServer/BridgeRequestHandler.swift` | HTTP route definitions, threading model |
| EventBus | Swift | `ClawGate/Core/EventBus/EventBus.swift` | In-memory ring buffer (max 1000), cursor-based polling, SSE |
| RecentSendTracker | Swift | `Core/EventBus/RecentSendTracker.swift` | Swift-side echo detection (120s window) |
| FederationServer | Swift | `Core/Federation/FederationServer.swift` | WebSocket server, client management, event broadcast |
| FederationClient | Swift | `Core/Federation/FederationClient.swift` | WebSocket client, reconnect backoff, event forwarding |
| TmuxInboundWatcher | Swift | `Adapters/Tmux/TmuxInboundWatcher.swift` | CC session monitoring, question detection, auto-answer |
| TmuxAdapter | Swift | `Adapters/Tmux/TmuxAdapter.swift` | Mode-gated send, session listing |
| CCStatusBarClient | Swift | `Adapters/Tmux/CCStatusBarClient.swift` | WebSocket to cc-status-bar, session state tracking |
| LINEInboundWatcher | Swift | `Adapters/LINE/LINEInboundWatcher.swift` | AX/Pixel/Notification fusion, inbound dedup |
| LineTextSanitizer | Swift | `Adapters/LINE/Detection/LineTextSanitizer.swift` | Echo normalization, UI chrome filtering |
| AppConfig | Swift | `Core/Config/AppConfig.swift` | Session modes, UserDefaults persistence |
| gateway.js | JS | `extensions/openclaw-plugin/src/gateway.js` | Poll loop, event dispatch, deliver callback, echo suppression |
| outbound.js | JS | `extensions/openclaw-plugin/src/outbound.js` | sendText with ensurePrefix |
| context-reader.js | JS | `extensions/openclaw-plugin/src/context-reader.js` | Stable + dynamic context building |
| context-cache.js | JS | `extensions/openclaw-plugin/src/context-cache.js` | Hash-based context cache, progress trails, task goals |
| shared-state.js | JS | `extensions/openclaw-plugin/src/shared-state.js` | Active project bridge (60s TTL) |
| client.js | JS | `extensions/openclaw-plugin/src/client.js` | HTTP client (clawgateSend, clawgatePoll, etc.) |

### Data Flow Overview

```
LINE App (macOS)                          Tmux (Claude Code sessions)
     |                                          |
     v                                          v
LINEInboundWatcher                     CCStatusBarClient (WS :8080-8089)
  (AX + Pixel + Notification)                   |
     |                                     TmuxInboundWatcher
     v                                    (question/completion/progress)
EventBus.append()  <-----------------------+    |
     |                                          v
     +-- FederationServer.broadcast() -------> EventBus.append()
     |                                          |
     v                                          |
/v1/poll (gateway.js)  <------------------------+
     |
     v
gateway.js event handlers
  handleInboundMessage()
  handleTmuxQuestion()
  handleTmuxCompletion()
     |
     v
OpenClaw AI dispatch (deliver callback)
     |
     v
normalizeLineReplyText() / ensurePrefix()
     |
     v
clawgateSend() --> POST /v1/send --> LINE App
```

---

## 2. HTTP API Endpoints

### Server Architecture

- **Framework**: SwiftNIO (async I/O)
- **Port**: 8765 (localhost by default; 0.0.0.0 if remoteAccessEnabled)
- **Blocking queue**: `BlockingWork.queue` (serial DispatchQueue, QoS: userInitiated)
- **Threading**: Non-blocking endpoints respond on NIO EventLoop; blocking endpoints dispatch to BlockingWork.queue

### Global Response Format

```json
{ "ok": true,  "result": <T>,   "error": null }
{ "ok": false, "result": null,  "error": <ErrorPayload> }
```

### ErrorPayload

| Field | Type | Description |
|-------|------|-------------|
| `code` | string | Machine-readable error code |
| `message` | string | Human-readable message |
| `retriable` | bool | true -> HTTP 503; false -> 400/403/404 |
| `failed_step` | string? | Pipeline stage where failure occurred |
| `details` | string? | Debug context |

### Authentication & CSRF

- **Bearer token**: Active only when `remoteAccessEnabled = true`. Header: `Authorization: Bearer <token>`
- **CSRF**: POST requests with `Origin` header are rejected (403 `browser_origin_rejected`)
- **Trace ID**: Optional `X-Trace-ID` header; auto-generated as `trace-<UUID>` if absent

### Endpoint Table

| # | Method | Path | Threading | Tracked | Purpose |
|---|--------|------|-----------|---------|---------|
| 1 | GET | `/v1/health` | EventLoop | No | Liveness probe (version) |
| 2 | GET | `/v1/config` | EventLoop | No | Read config (masks LINE on client) |
| 3 | POST | `/v1/send` | Blocking | Yes | Send message via adapter |
| 4 | GET | `/v1/poll` | EventLoop | No | Cursor-based event polling |
| 5 | GET | `/v1/events` | EventLoop/SSE | No | Server-Sent Events stream |
| 6 | GET | `/v1/stats` | EventLoop | No | Day stats + history |
| 7 | GET | `/v1/ops/logs` | EventLoop | No | Structured ops logs |
| 8 | GET | `/v1/context` | Blocking | Yes | Conversation context (AX) |
| 9 | GET | `/v1/messages` | Blocking | Yes | Recent visible messages |
| 10 | GET | `/v1/conversations` | Blocking | Yes | Available conversations |
| 11 | GET | `/v1/axdump` | Blocking | Yes | Accessibility tree dump |
| 12 | GET | `/v1/doctor` | Blocking | Yes | System health diagnostic |
| 13 | GET | `/v1/openclaw-info` | EventLoop | Yes | OpenClaw gateway config |
| 14 | POST | `/v1/debug/inject` | Blocking | Yes | Inject synthetic event |

### Key Endpoint Details

#### POST /v1/send

Request:
```json
{
  "adapter": "line|tmux|gateway",
  "action": "send_message",
  "payload": {
    "conversation_hint": "project-name",
    "text": "message text",
    "enter_to_send": true
  }
}
```

Response:
```json
{
  "ok": true,
  "result": {
    "adapter": "tmux",
    "action": "send_message",
    "message_id": "uuid",
    "timestamp": "ISO8601"
  }
}
```

**Federation fallback**: If adapter=tmux fails with `session_not_found` or `tmux_target_missing` and FederationServer has connected clients, forwards to federation.

For `adapter=line`, search navigation is sidebar-scoped:
- ClawGate finds the left sidebar result list after search confirmation
- It clicks the first visible sidebar result row instead of the first global `AXRow`
- Retries may fail with `search_result_not_found` when the search sidebar is visible but exposes no clickable result row

#### GET /v1/conversations

For `adapter=line`, conversation discovery is layered:
- AX sidebar list discovery (`AXList` + visible `AXRow`s in the left pane)
- AX text extraction inside visible sidebar rows
- OCR fallback on visible sidebar row crops when AX rows are textless

Failure remains wire-compatible:
- `sidebar_not_visible` is still the error code
- `error.details` distinguishes `sidebar_list_not_found`, `ocr_window_id_missing`, and `ocr_unavailable_or_empty`

#### GET /v1/poll

Query: `?since=<Int64>` (cursor; omit for all buffered)

Response:
```json
{
  "ok": true,
  "events": [{ "id": 123, "type": "...", "adapter": "...", "payload": {...}, "observed_at": "ISO8601" }],
  "next_cursor": 124
}
```

#### GET /v1/events (SSE)

- Header `Last-Event-ID`: resume from ID; if absent, replay last 3 events
- Format: `id: <id>\ndata: <BridgeEvent JSON>\n\n`

### Error Codes

| Code | HTTP | Retriable | Context |
|------|------|-----------|---------|
| `browser_origin_rejected` | 403 | No | CSRF: POST with Origin |
| `unauthorized` | 401 | No | Invalid Bearer token |
| `invalid_json` | 400 | No | Body decode failure |
| `adapter_not_found` | 400 | No | Unknown adapter |
| `session_not_found` | 503 | Yes | Tmux session missing |
| `session_read_only` | 400 | No | Observe mode send attempt |
| `forbidden_key` | 400 | No | C-c, C-d, C-z, C-\ blocked |
| `line_disabled_on_client` | 403 | No | Client node accessing LINE |

---

## 3. Event System

### BridgeEvent Structure

```swift
struct BridgeEvent: Codable {
    let id: Int64              // Auto-incrementing, starts at 1
    let type: String           // Event type
    let adapter: String        // Source adapter
    let payload: [String: String]
    let observedAt: String     // ISO8601
}
```

### Event Types

| Type | Adapters | Description |
|------|----------|-------------|
| `inbound_message` | line, tmux | Message received |
| `outbound_message` | line, tmux | Message sent (after success) |
| `echo_message` | line | Self-echo detected by RecentSendTracker |
| `federation_status` | federation | Connection state changes |

### Adapter Values

- `"line"` -- LINE app
- `"tmux"` -- Claude Code / Codex sessions
- `"federation"` -- Federation subsystem

### Tmux Source Types

The `source` payload field for tmux `inbound_message` events:

| Source | Trigger | When |
|--------|---------|------|
| `completion` | running -> waiting_input | Task finished |
| `question` | AskUserQuestion menu detected | Menu with options visible |
| `progress` | 60s timer or cc-status-bar WS (20s) | Periodic snapshot |

### Payload Fields by Source

#### LINE inbound_message / echo_message

| Field | Description |
|-------|-------------|
| `text` | Sanitized message text |
| `conversation` | Chat window name |
| `source` | Detection signal: structural, pixel, process, hybrid_fusion |
| `confidence` | high / medium / low |
| `score` | 0-100 |
| `signals` | Comma-separated signal names |
| `pipeline_version` | line-legacy-v2 / line-hybrid-v1 |

#### Tmux inbound_message (completion)

| Field | Description |
|-------|-------------|
| `text` | Output summary (up to 12000 chars) |
| `conversation` | Project name |
| `source` | `"completion"` |
| `project` | Project name |
| `tmux_target` | session:window.pane |
| `sender` | claude_code / codex |
| `mode` | observe / auto / autonomous / ignore |
| `capture` | pane / progress_fallback / idle_bootstrap |
| `event_id` | UUID |
| `session_type` | claude_code / codex |

#### Tmux inbound_message (question)

All completion fields plus:

| Field | Description |
|-------|-------------|
| `question_text` | Full question text |
| `question_options` | Options separated by `\n` |
| `question_selected` | 0-based selected index |
| `question_id` | Timestamp-based dedup ID |

#### Tmux inbound_message (progress)

Same fields as completion but `source = "progress"`.

#### LINE outbound_message

| Field | Description |
|-------|-------------|
| `text` | First 100 chars of sent message |
| `conversation` | Target conversation |
| `trace_id` | Request trace ID |

#### federation_status

| Field | Description |
|-------|-------------|
| `state` | start, connecting, connected, closed, error, disabled, invalid_url, receive_failed, send_failed |
| `detail` | Status detail (max 160 chars) |

### EventBus Internals

- **Storage**: In-memory array, max 1000 events (oldest dropped on overflow)
- **ID**: Auto-incrementing Int64, never reused
- **Thread safety**: NSLock
- **Polling**: `poll(since:)` returns events with `id > since` + `nextCursor`
- **SSE**: Subscribe with callback; Last-Event-ID for replay
- **Subscribers**: Callback-based via `subscribe()` / `unsubscribe()`

---

## 4. Message Delivery Paths

There are **two distinct delivery mechanisms** from AI to the messenger layer (Telegram for CC/Cdx development traffic, LINE for normal secretary workflows):

### Path 1: Deliver Callback (gateway.js -- Primary)

Used by the three event handlers:

| Handler | Trigger | Special Tags |
|---------|---------|--------------|
| `handleInboundMessage()` | LINE inbound | `<cc_task>`, `<cc_answer>` |
| `handleTmuxQuestion()` | CC/Cdx question event | `<cc_answer>` (auto mode) |
| `handleTmuxCompletion()` | CC/Cdx completion event | `<cc_task>` (auto/autonomous) |

**Flow**:
```
Event -> buildMsgContext() -> recordInboundSession()
  -> dispatchReplyWithBufferedBlockDispatcher({deliver})
    -> AI processes context
    -> deliver(replyPayload)
      -> extractReplyText()
      -> [try extract <cc_answer> / <cc_task>]
      -> normalizeLineReplyText(text, {project, eventKind})
      -> sendTmuxMessage(conversation, finalText, traceId, {channel})
      -> recordPluginSend(finalText)
```

### Path 2: outbound.sendText (outbound.js -- Runtime)

Used when OpenClaw AI runtime sends directly (not via deliver callback).

**Flow**:
```
outbound.sendText({to, text, accountId, cfg})
  -> resolveAccount()
  -> getActiveProject(conversation)   // shared-state.js lookup
  -> ensurePrefix(text, project)      // add [CC project] if project found
  -> sendTmuxMessage(conversation, finalText, traceId?, {channel?})
```

### Comparison

| Aspect | Deliver Callback | outbound.sendText |
|--------|------------------|-------------------|
| Normalization | Full: newlines, markdown, headers | None |
| Prefix | `normalizeLineReplyText()` | `ensurePrefix()` + shared-state |
| Special tags | `<cc_answer>`, `<cc_task>` | No |
| Markdown strip | Yes | No |
| Newline collapse | Yes (3+ -> 2) | No |

### Text Normalization Pipeline (normalizeLineReplyText)

Steps (gateway.js lines 363-391):
1. `\r\n` / `\r` -> `\n`
2. Collapse 3+ consecutive newlines to 2
3. Remove trailing whitespace after newlines
4. Add blank line before `**bold**` markers, then strip them
5. Strip Markdown heading markers `#`
6. Add blank lines before section headers: `GOAL:`, `SCOPE:`, `RISK:`, `ARCHITECTURE:`, `MISSING:`, `SUMMARY:`, `VERDICT:`
7. Add `[CC project]\n` prefix (idempotent: strips existing prefix first)

### Prefix Guarantee (shared-state.js)

```
setActiveProject(conversation, project)   // gateway.js: before tmux dispatch
  -> activeDispatchProjects.set(conversation, {project, ts: Date.now()})

getActiveProject(conversation)            // outbound.js: during send
  -> returns project if entry < 60s old, else ""
```

Ensures both delivery paths produce `[CC projectname]\n...` when project is known.

### Special Tag Processing

#### `<cc_task>tasktext</cc_task>`
- Extracted from AI reply
- Prefixed with `[OpenClaw Agent - Mode]` (mode capitalized)
- Sent to CC via `clawgateTmuxSend()`
- Stored via `setTaskGoal(project, taskText)`
- **Autonomous mode**: Max 3 completion-task rounds (prevents loops)
- **Autonomous messenger policy**: development-session notifications go to Telegram only (`risk`, `interaction_pending`, `final`)
- **Autonomous decision boundary**: `<cc_task>` can guide and request changes, but final high-impact decisions still require explicit user GO.
- **Auto mode**: No round limit

#### `<cc_answer project="name">index</cc_answer>`
- Extracted from AI reply (auto mode questions)
- Index converted from 1-based to 0-based
- Sent as `__cc_select:index` via `clawgateTmuxSend()`
- Any tag-outside advisory text is routed to Telegram in development-session flows
- Pending question removed from map

---

## 5. Federation Protocol

### Connection

- **Transport**: WebSocket at `ws://host:8765/federation`
- **Direction**: Host B (FederationClient) -> Host A (FederationServer)
- **Auth**: Bearer token in initial request headers

### Envelope Format

```json
{
  "type": "hello|ping|pong|event|command|response",
  "timestamp": "ISO8601",
  "payload": { ... }
}
```

All frames are JSON text frames over WebSocket.

### Frame Types

#### hello (Client -> Server)

```json
{
  "type": "hello",
  "timestamp": "...",
  "payload": { "version": "0.1.0", "capabilities": ["line", "tmux"] }
}
```

Server responds with `welcome`:
```json
{ "type": "welcome", "timestamp": "...", "payload": { "server_version": "0.1.0" } }
```

#### ping / pong (Bidirectional)

```json
{ "type": "ping", "timestamp": "...", "payload": {} }
{ "type": "pong", "timestamp": "...", "payload": { "ok": true } }
```

#### event (Bidirectional -- Broadcast)

```json
{
  "type": "event",
  "timestamp": "...",
  "payload": {
    "event": {
      "id": 123,
      "timestamp": "...",
      "adapter": "tmux",
      "type": "inbound_message",
      "payload": { "text": "...", "project": "...", "mode": "auto", ... }
    }
  }
}
```

**Filter rules**:
- Skip if `_from_federation == "1"` (echo prevention)
- Server only forwards: tmux adapter, outbound_message, inbound_message
- `federation_status` events never forwarded

#### command (Server -> Client)

```json
{
  "type": "command",
  "timestamp": "...",
  "payload": {
    "id": "cmd-uuid",
    "method": "POST",
    "path": "/v1/send",
    "headers": { "Content-Type": "application/json", "X-Trace-ID": "..." },
    "body": "{\"action\":\"send_message\",\"payload\":{...}}"
  }
}
```

Supported forwarded endpoints: `/v1/health`, `/v1/config`, `/v1/poll`, `/v1/send`, `/v1/context`, `/v1/messages`, `/v1/conversations`, `/v1/axdump`, `/v1/doctor`, `/v1/openclaw-info`

#### response (Client -> Server)

```json
{
  "type": "response",
  "timestamp": "...",
  "payload": {
    "id": "cmd-uuid",
    "status": 200,
    "headers": { "Content-Type": "application/json; charset=utf-8" },
    "body": "{\"ok\":true,\"result\":{...}}"
  }
}
```

### Mode Resolution

Both server and client independently resolve mode:

```
effectiveMode = localConfig[modeKey(sessionType, project)] ?? event.payload["mode"] ?? "ignore"
if effectiveMode == "ignore" -> drop event
```

**Priority**: Local config > event mode > "ignore" (default)

### Echo Prevention

1. Receiving node marks event: `payload["_from_federation"] = "1"`
2. Subscription filter skips events with `_from_federation == "1"`
3. `federation_status` events never forwarded (connection noise)

### Command Forwarding Pipeline

```
Server: POST /v1/send fails (session_not_found / tmux_target_missing)
  -> federationServer.hasConnectedClient()?
    -> forwardToFederationClient()
      -> FederationCommandPayload{id, method, path, headers, body}
      -> sendCommand(forProject: project)
        -> route: projectRoutes[project] or broadcast to first client
      -> wait for promise (EventLoopFuture)

Client: receives "command" frame
  -> core.handleFederationCommand(command)
  -> route to local HTTP handler
  -> wrap result as FederationResponsePayload
  -> send "response" frame

Server: promise resolves
  -> convert FederationResponsePayload to HTTPResult
  -> return to original HTTP caller
```

### Reconnection

- **Backoff**: `min(2^min(attempt, 6), maxDelay)` -- 2s, 4s, 8s, 16s, 32s, 64s cap
- **Reset**: `reconnectAttempts = 0` on successful connection
- **Triggers**: connection close, URLSession error, receive loop error

---

## 6. Session Modes & Access Control

### Mode Definitions

| Mode | Config Value | Send Allowed | Question Handling | Event Routing |
|------|-------------|--------------|-------------------|---------------|
| `ignore` | absent from dict | No (session_not_found) | N/A | No monitoring |
| `observe` | `"observe"` | No (session_read_only) | Emit event | EventBus (read-only) |
| `auto` | `"auto"` | Yes | Auto-answer locally | EventBus (completion/progress) |
| `autonomous` | `"autonomous"` | Yes | Emit event for Chi | EventBus -> OpenClaw Agent |

### Config Key Format

```swift
static func modeKey(sessionType: String, project: String) -> String {
    let prefix = sessionType == "codex" ? "codex" : "cc"
    return "\(prefix):\(project)"
}
```

Examples: `cc:clawgate`, `codex:experiment`

Storage: `UserDefaults "clawgate.tmuxSessionModes"` (JSON dict)

### Mode Resolution (TmuxAdapter)

```swift
func sessionMode(for session: CCSession) -> String {
    modes[AppConfig.modeKey(sessionType: session.sessionType, project: session.project)] ?? "ignore"
}
```

### Auto Mode: Auto-Answer Logic

**Trigger**: Session transitions to `waiting_input` with detected AskUserQuestion menu.

**Algorithm** (TmuxInboundWatcher):
1. Scan options for affirmative keywords (priority order):
   - `(recommended)`, `don't ask`, `always`, `yes`, `ok`, `proceed`, `approve`
2. Select first matching option; default to index 0
3. Navigate tmux menu (arrow keys) and press Enter
4. Multi-step wizard: retry up to 10 times with 1.5s sleep

**Permission prompts**: Auto-approve with `y` key (auto/autonomous modes only).

### Autonomous Mode: External Control

- Events emitted to EventBus with structured payload (mode, question_text, question_options, etc.)
- OpenClaw Agent (Chi) receives via poll, processes, sends `<cc_task>` or `<cc_answer>` back
- Messages to CC prefixed (canonical): `[from:OpenClaw Agent - Autonomous]`
  - Backward-compatible receive forms: `[OpenClaw Agent - Autonomous]`, `[from: OpenClaw Agent - Autonomous]`
- Round limit: 3 completion-task cycles (prevents infinite loops; resets on human message)

#### Autonomous Role Charter (Normative)

- **Purpose**: When the user is away, Chi acts as an advisor between user and development sessions (CC/Cdx): surface problems, propose direction, and keep progress moving.
- **Authority boundary**: Chi has no decision authority. Product/implementation go-no-go decisions remain with the user.
- **Bridge responsibility**: Chi translates CC/Cdx progress into user-facing, decision-ready updates and translates user intent back into actionable `<cc_task>` guidance.
- **GO gate**: Autonomous flow must end in a user decision gate. Chi can recommend, but must not finalize high-impact decisions (spec changes, destructive changes, releases, security-impacting ops) without explicit user GO.
- **Advisor behavior**: Be specific, challenge weak reasoning, request justification when needed, and keep recommendations actionable.
- **Forbidden behavior**: low-information chatter, pseudo-progress updates without new evidence, or language that implies Chi already decided for the user.

#### Autonomous Telegram Contract (Normative)

- Telegram is the milestone channel for autonomous mode (`risk`, `interaction_pending`, `final`), not a full transcript.
- `kickoff` and mid-loop chatter stay in-session.
- Routing failures (`session_typing_busy`, `session_busy`, read-only/session mode blocks, transient send failures) are **ops-only** and do not emit Telegram chatter.
- Interactive choice prompts are an exception: send a recommendation to Telegram (`interaction_pending`) so the user can decide.
- On interactive prompts, `<cc_task>` and `<cc_answer>` are blocked from execution (advisor-only behavior).
- `interaction_pending` notifications are deduplicated by project + question fingerprint (default 60s window).
- This loop guard is enabled by default; set `CLAWGATE_AUTONOMOUS_LOOP_GUARD_V2=0` to revert to legacy behavior.
- Final wrap-up must include:
  1. Conclusion / recommendation
  2. Evidence (1-2 concrete points)
  3. Next action for user GO

#### Interactive Choice Guard (Normative)

- `gateway.js` keeps `interactionPendingProjects` (TTL 5 minutes) keyed by project.
- Guard is set when:
  - a tmux `question` event arrives, or
  - an `autonomous` completion has structured interactive evidence (e.g. `waiting_reason=permission_prompt`, option markers, pending-question context).
- `? for shortcuts` footer alone is insufficient in strict mode (enabled by default).
- Set `CLAWGATE_INTERACTION_PENDING_STRICT_V2=0` to revert to legacy permissive detection.
- While guard is active, task routing is blocked:
  - `tryExtractAndSendTask()` returns `errorCode="interaction_pending"`.
  - Any `<cc_task>` / `<cc_answer>` text in AI reply is stripped before Telegram forwarding.
- Guard clears on:
  - successful `<cc_answer>` send,
  - tmux `progress` event (new execution resumed),
  - normal completion without interaction signal.
- Trace/ops signals:
  - `interaction_pending_detected`
  - `interaction_pending_blocked`
  - `autonomous_line reason=interaction_pending`

### Forbidden Keys

Blocked in TmuxShell to prevent session destruction:

| Key | Signal | Why |
|-----|--------|-----|
| `C-c` | SIGINT | Interrupts Claude Code |
| `C-d` | EOF | Exits tmux pane |
| `C-z` | SIGTSTP | Suspends process |
| `C-\` | SIGQUIT | Core dump |

### CCStatusBarClient

WebSocket client to `cc-status-bar` service, auto-scans ports 8080-8089.

**CCSession fields**: id, project, status (running/waiting_input/stopped), sessionType (claude_code/codex), tmuxSession/Window/Pane, isAttached, attentionLevel, waitingReason, paneCapture.

**Messages**: `sessions.list`, `session.updated`, `session.progress`, `session.added`, `session.removed`.

---

## 7. Echo Suppression & Dedup

### Layer 1: Plugin Echo Suppression (gateway.js)

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `ECHO_WINDOW_MS` | 45,000 ms | Time window for echo matching |
| `COOLDOWN_MS` | 5,000 ms | Immediate strict-exact echo guard window (metrics/log context) |

**recordPluginSend(text)**: Called after every `clawgateSend()`. Stores trimmed text + timestamp. Prunes entries > 45s.

**isPluginEcho(eventText)**:
1. Tune v2: inside cooldown, only strict exact-short echo is suppressed (no blanket drop)
2. Legacy mode: first-40-char substring check
3. Tune v2 (`CLAWGATE_INGRESS_DEDUP_TUNE_V2=1`): ratio-based full-text match (exact / dominance / coverage) + multi-line echo check

### Layer 2: Swift RecentSendTracker

| Parameter | Value |
|-----------|-------|
| Window | 120 seconds |
| Matching | `LineTextSanitizer.textLikelyContainsSentText()` |

**normalizeForEcho()**: lowercase -> diacritic fold -> width fold -> keep only alphanumerics + hiragana + katakana + CJK.

**textLikelyContainsSentText(candidate, sentText)**:
- Min length: 6 chars (after normalization)
- Exact match: true
- Candidate contains sent: dominance >= 0.70 (sent is 70%+ of candidate)
- Sent contains candidate: coverage >= 0.85 (candidate is 85%+ of sent)

### Layer 3: Swift Inbound Dedup (LINEInboundWatcher)

- Legacy:
  - **Window**: 20 seconds
  - **Fingerprint**: `conversation.lowercased() + "|" + normalizeForEcho(text)`
- Tune v2 (`CLAWGATE_INGRESS_DEDUP_TUNE_V2=1`):
  - **Window**: env `CLAWGATE_LINE_INBOUND_DEDUP_WINDOW_SEC` (default 8s)
  - **Fingerprint**: width/diacritic-folded lowercase text with whitespace normalized (less destructive than normalizeForEcho)
  - Short fingerprints (<6 chars) are not deduped

### Layer 4: JS Inbound Dedup (gateway.js)

```javascript
const DEDUP_WINDOW_MS = 0;           // legacy default (disabled)
const STALE_REPEAT_WINDOW_MS = 0;    // legacy default (disabled)
// tune v2 when CLAWGATE_INGRESS_DEDUP_TUNE_V2=1
const DEDUP_WINDOW_MS_V2 = 8000;
const STALE_REPEAT_WINDOW_MS_V2 = 20000;
```

- Legacy default keeps dedup disabled for recall-first behavior.
- Tune v2 enables bounded dedup windows to reduce repeated ingress bursts.
- Additional tune v2 guards:
  - `COMMON_INGRESS_DEDUP_WINDOW_MS` (default 45s): compact-key dedup for near-identical OCR variations
  - `SHORT_LINE_DEDUP_WINDOW_MS` (default 25s): short single-line repeats (e.g., "ほーい")

### Layer 5: LINE Burst Coalescing (gateway.js)

To avoid reply floods when one human input is split into multiple OCR ingress events:

- Enabled by default: `CLAWGATE_LINE_BURST_COALESCE=1`
- Window: `CLAWGATE_LINE_BURST_COALESCE_WINDOW_MS` (default 1500ms)
- Behavior:
  - Buffer accepted LINE ingress per conversation inside the coalesce window
  - Merge fragments (longest-first + line-level novelty merge)
  - Dispatch once to AI and LINE with `coalesce_count` metadata
  - Flush pending buffer on gateway shutdown

### Detection Latency Telemetry

`LINEInboundWatcher` now stamps timing fields on emitted line events:

- `line_watch_poll_started_at`
- `line_watch_capture_done_at`
- `line_watch_signal_collect_done_at`
- `line_watch_fusion_done_at`
- `line_watch_eventbus_appended_at`
- `line_watch_capture_ms`
- `line_watch_signal_collect_ms`
- `line_watch_fusion_ms`
- `line_watch_total_detect_ms`

Gateway trace (`clawgate_trace`) propagates:

- `ingress_age_ms` (EventBus observed_at -> gateway receive)
- line watcher timing fields (when present)

### Inbound Normalization

#### JS: normalizeInboundText()

1. Clean line endings (`\r\n`, `\r` -> `\n`)
2. Normalize whitespace per line
3. Filter UI chrome via `isUiChromeLine()`: 既読, 未読, LINE, timestamps, symbol-only
4. Merge OCR wrap fragments via `mergeWrappedLines()`: short tails (<=36), heads (<=20)
5. Fallback: if all filtered, keep last raw non-empty line

#### Swift: LineTextSanitizer.sanitize()

1. Normalize line endings
2. Trim lines, drop empty
3. Filter `isStandaloneUIArtifact()`: 既読, 未読, もっと見る, 入力中, time-only, symbol-only
4. Drop short ASCII crumbs if 2+ real lines remain

### Cross-Source Fusion (LINEInboundWatcher)

Three detection signals fused:

| Source | Signal | Score |
|--------|--------|-------|
| AXRow | Structural change in chat rows | 70 (count) / 58 (bottom) |
| PixelDiff | Image hash change + OCR | 62 (text change) / 35 (no text) |
| NotificationBanner | macOS notification | 95 (highest confidence) |

---

## 8. Context System

### Two-Layer Architecture

| Layer | Purpose | Budget | Cached | Sent |
|-------|---------|--------|--------|------|
| Stable | CLAUDE.md + referenced files | 12,000 chars | 5min TTL + hash dedup | Only when hash changes |
| Dynamic | Git state + diff + work logs | 2,500 chars | Never | Every dispatch |

### Stable Context (buildStableContext)

1. Read CLAUDE.md
2. Extract referenced files (backtick paths, `docs/` prefix, `.ext`)
3. Priority: CLAUDE.md -> referenced files -> fallbacks (AGENTS.md, README.md)
4. Smart truncation: prioritize headings + IMPORTANT/CRITICAL/NEVER/MUST lines
5. Per-file limit: 4,000 chars; total: 12,000 chars
6. Hash computed for dedup against `sentHash`

**Dedup**: If hash unchanged from last send, emit placeholder: `[Project Context unchanged (hash: xxx)]`

### Dynamic Envelope (buildDynamicEnvelope)

1. Git branch + last 3 commits
2. Last commit diff stat (capped 500 chars)
3. Recent work logs: 2 entries from `docs/log/claude/` (300 chars each)

### Read-only Project View Overlay (`project-view.js`)

Observe / Autonomous dispatches can append a read-only doc snapshot via external wrapper command.

- Command (default): `chi-projects-read`
- Purpose: supply project docs when local tmux path resolution cannot build stable context (federated/remote sessions)
- Injection rule (default): only when stable context is unavailable
- Optional override: `forceWhenStableExists=true`

Root resolution order:
1. `projectView.projects[project].root`
2. `projectView.projectRoots[project]`
3. Derived from resolved absolute project path under `projectView.rootPrefix` (default `/Users/usedhonda/projects`)

File list resolution order:
1. `projectView.projects[project].files`
2. `projectView.projectFiles[project]`
3. `projectView.defaultFiles` (default: `AGENTS.md`, `CLAUDE.md`, `README.md`)

Safety behavior:
- Read-only subcommand only (`read`)
- Missing command or read failure -> overlay suppressed (dispatch continues)
- Per-project cache with TTL
- Total/doc caps enforced before insertion

`channels.clawgate.<accountId>.projectView` example:

```json
{
  "enabled": true,
  "command": "chi-projects-read",
  "rootPrefix": "/Users/usedhonda/projects",
  "projectRoots": {
    "clawgate": "ios/clawgate"
  },
  "projectFiles": {
    "clawgate": ["AGENTS.md", "CLAUDE.md", "docs/SPEC-messaging.md"]
  },
  "ttlMs": 90000
}
```

### Task Goal Tracking

```javascript
setTaskGoal(project, goalText)    // on <cc_task> send
getTaskGoal(project)              // on completion dispatch -> "[Task Goal]\n..."
clearTaskGoal(project)            // after completion dispatch
```

### Progress Trail

```javascript
appendProgressTrail(project, text)   // on progress events
getProgressTrail(project)            // on completion -> "[Execution Progress Trail]\n..."
clearProgressTrail(project)          // after completion
```

- Max 6 entries, 2,000 chars total
- Dedup: skip if identical to last entry
- Noise filtering: strips spinners, meters, model indicators, token stats, separators

### Project Roster (buildProjectRoster)

Compact summary of all active CC projects, prepended to secretary-facing LINE inbound context:

```
[Active Claude Code Projects: 2 sessions]
- clawgate (main) [autonomous] waiting_input [ASKING: should I use OAuth?]
- myapp (feature-x) [observe] running
  Latest output: Running tests...
```

### Pairing Guidance (buildPairingGuidance)

Sent once per project on first dispatch (tracked via `guidanceSentProjects` set):

- Mode-specific review instructions for Chi
- Section header formatting rules (LINE has no Markdown)
- Review angles: GOAL, SCOPE, RISK, ARCHITECTURE, MISSING
- Per-event behavior matrix (completion/question x auto/autonomous/observe)
- Observe contract: adaptive 3-8 lines with GOAL/SCOPE/RISK always covered

### Prompt Profiles (gateway.js)

Prompt loading order (once at startup):
1. `src/prompts.js` (tracked core)
2. `src/prompts-local.js` (repo-local optional)
3. `~/.clawgate/prompts-private.js` (private overlay, recommended)

Validation and guardrails:
- Structural validation for required prompt keys
- Protected contract sections auto-restored from core if missing:
  - `completion.observe`
  - `completion.autonomous`
- Startup logs include prompt profile version/hash/layers

### Context Assembly on Completion

Priority-aware assembly:
1. Required: pairing guidance + completion output text
2. Optional: stable context, knowledge, task goal, dynamic envelope, progress trail
3. Optional context is capped first; required segments are preserved whenever possible

After dispatch: `markContextSent(project, hash)`, `invalidateProject(project)`, `clearTaskGoal()`, `clearProgressTrail()`

### Constants

```
MAX_STABLE_CHARS   = 12,000
MAX_ENVELOPE_CHARS =  2,500
MAX_FILE_CHARS     =  4,000
MAX_LOG_CHARS      =    300
MAX_TRAIL_ENTRIES   =     6
MAX_TRAIL_CHARS    =  2,000
CONTEXT_TTL_MS     = 300,000  (5 min)
PROJECT_VIEW_TTL_MS = 90,000
PROJECT_VIEW_MAX_TOTAL_CHARS = 5,000
INTERACTION_PENDING_TTL_MS = 300,000 (5 min)
ECHO_WINDOW_MS     =  45,000
COOLDOWN_MS        =   5,000
DEDUP_WINDOW_MS    =       0  (disabled)
MAX_ROUNDS         =       3  (autonomous)
ACTIVE_PROJECT_TTL =  60,000  (shared-state)
```
