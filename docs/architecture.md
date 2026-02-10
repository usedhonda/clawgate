# ClawGate Architecture

## Components

### UI Layer
- **MenuBarApp** (`NSStatusItem`): Menu bar icon, status display, settings, tmux sessions submenu
- **SettingsView** (`SwiftUI`): Configuration panel for general, LINE, and tmux settings
- **QRCodeView**: QR code display for pairing (unused in current flow)

### Core
- **BridgeServer**: SwiftNIO HTTP/1.1 server bound to `127.0.0.1:8765`. Sets up the channel pipeline and accepts connections.
- **BridgeRequestHandler**: HTTP routing and request dispatch. Routes 10 endpoints, offloads AX-dependent work to `BlockingWork.queue`.
- **BridgeCore**: Business logic for all endpoints (health, config, doctor, send, context, messages, conversations, poll, axdump).
- **BridgeModels**: All Codable request/response types (SendPayload, SendResult, ErrorPayload, APIResponse, DoctorReport, ConfigResult, etc.).
- **BridgeRuntimeError**: Structured error type with code, message, retriable flag, and failed step.
- **EventBus**: In-memory ring buffer (max 1000 events), auto-incrementing Int64 IDs, thread-safe via NSLock. Supports poll (since cursor) and SSE subscriber callbacks.
- **RecentSendTracker**: Tracks recent send_message calls for echo suppression (8-second temporal window).
- **ConfigStore**: UserDefaults-backed configuration with migration support for legacy keys.
- **AppLogger**: Leveled logging (debug/info/warning/error).
- **StepLog**: Per-step operation log for send flows.

### Automation
- **AXQuery**: AXUIElement tree traversal and descendant search.
- **AXActions**: setValue, press, focus, paste, keyboard events (including `AXUIElementPostKeyboardEvent` via dlsym).
- **AXAppWindow**: App/window resolution helpers (activate, reopen, focused window).
- **AXDump**: Full AX tree serialization for debugging.
- **VisionOCR**: Screen capture + Vision framework text recognition for inbound message text extraction.
- **SelectorResolver**: Multi-layer UI element scoring (identifier, text, permission, geometry).
- **UniversalSelector**: Selector definition struct with matching criteria.
- **GeometryHint**: Spatial filtering (top/bottom/left/right of window).
- **RetryPolicy**: Exponential backoff with configurable max attempts.

### Adapters

#### LINEAdapter
- Implements `AdapterProtocol` for LINE Desktop (Qt, `jp.naver.line.mac`)
- `sendMessage`: activate -> search conversation -> navigate -> set text -> send Enter
- `getContext`: Read current conversation name and input field state
- `getMessages`: Extract visible messages with sender classification and y-order
- `getConversations`: List sidebar conversations with unread status

#### TmuxAdapter
- Implements `AdapterProtocol` for Claude Code sessions running in tmux
- Relies on `CCStatusBarClient` for session discovery and `TmuxShell` for CLI interaction
- Session mode resolution: ignore / observe / auto / autonomous
- `sendMessage`: Resolve session -> validate mode -> send keys to tmux pane
- `__cc_select:N`: Menu navigation via Up/Down + Enter key sequences
- Read methods (`getContext`, `getMessages`, `getConversations`) return `not_supported`

### Inbound Detection

#### NotificationBannerWatcher (Primary LINE Detection)
- Event-driven: AXObserver on `com.apple.notificationcenterui` for `kAXWindowCreatedNotification`
- Fallback: 2-second polling to catch missed banners
- Extracts sender and message text from banner AX tree (standard AXStaticText, no OCR)
- Fingerprint deduplication (10-second window)
- Emits events with confidence=high, score=95

#### LINEInboundWatcher (Secondary LINE Detection)
- AX polling of LINE window at configurable interval (default 2s)
- Two detection modes:
  - **Legacy**: First signal wins (AX row count or pixel diff)
  - **Hybrid**: Multi-signal fusion via `LineDetectionFusionEngine`
- Signals: `ax_structure` (row count / position), `pixel_diff` (image hash / OCR text change)

#### LineDetectionFusionEngine
- Aggregates signals with score-based threshold evaluation
- Score ranges: ax_structure (58-70), pixel_diff (35-48)
- Confidence levels: high (>=80), medium (>=50), low (<50)
- Configurable threshold (default: 60)

#### TmuxInboundWatcher
- Monitors CCStatusBarClient state changes (running -> waiting_input)
- Distinguishes completions from AskUserQuestion prompts
- Auto-approves permission prompts (auto/autonomous modes)
- Emits progress events for running sessions (20s interval)

#### Echo Suppression
- `RecentSendTracker`: 8-second temporal window
- Any recent send within the window marks detection as likely echo
- Echo events emitted as `echo_message` type (not `inbound_message`)

### Extensions

#### openclaw-plugin
- OpenClaw channel plugin (plain JS, ESM)
- Polls ClawGate `/v1/poll` for inbound events and dispatches to OpenClaw runtime
- Sends outbound messages via `/v1/send`
- Handles tmux completions, questions, and progress events
- Context caching and directory integration

#### vibeterm-telemetry
- OpenClaw plugin for iOS location telemetry
- Receives background location batches via `POST /api/telemetry`
- UUID deduplication, in-memory store, daily diary file output

## API Surface

All endpoints on `http://127.0.0.1:8765`, no authentication required.

| Method | Path | Blocking | Description |
|--------|------|----------|-------------|
| GET | `/v1/health` | No | Version check |
| GET | `/v1/config` | No | Current configuration |
| GET | `/v1/doctor` | Yes | System diagnostics |
| GET | `/v1/poll` | No | Event polling |
| GET | `/v1/events` | No (SSE) | Real-time event stream |
| GET | `/v1/context` | Yes | Current conversation context |
| GET | `/v1/messages` | Yes | Visible chat messages |
| GET | `/v1/conversations` | Yes | Conversation list |
| GET | `/v1/axdump` | Yes | Raw AX tree dump |
| POST | `/v1/send` | Yes | Send message via adapter |

CSRF protection: POST requests with an `Origin` header are rejected (HTTP 403).

## Threading Model

```
┌─────────────────────────────────┐
│  NIO EventLoop (1 thread)       │  Handles: health, config, poll, SSE write, response write
│  NEVER does blocking work       │
└──────────┬──────────────────────┘
           │ offload via BlockingWork.queue.async { }
           v
┌─────────────────────────────────┐
│  BlockingWork.queue             │  Serial DispatchQueue (.userInitiated)
│  (com.clawgate.blocking)       │  Handles: AX queries, send, doctor, adapter calls
└─────────────────────────────────┘
           │ context.eventLoop.execute { writeResponse }
           v
      Back to NIO EventLoop

┌─────────────────────────────────┐
│  CCStatusBarClient              │  URLSession WebSocket (background thread)
│  WebSocket to cc-status-bar     │  State change callbacks -> BlockingWork.queue
└─────────────────────────────────┘

┌─────────────────────────────────┐
│  Main RunLoop (CFRunLoop)       │  AXObserver notifications (NotificationBannerWatcher)
│  NSApplication event loop       │  UI updates, menu bar
└─────────────────────────────────┘
```

**Why serial queue?** AX queries on LINE (Qt app) are not thread-safe. `BlockingWork.queue` serializes all AX access between HTTP handlers, LINEInboundWatcher, and TmuxInboundWatcher to prevent concurrent AXUIElement calls.

## Intel Mac Support

- Minimum target: macOS 12 (supports older Intel Mac mini environments)
- Build architecture handled by local toolchain (arm64 on Apple Silicon, x86_64 on Intel)
- Cross-build from Apple Silicon:
  ```bash
  swift build -Xswiftc -target -Xswiftc x86_64-apple-macos12.0
  ```
