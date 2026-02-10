# ClawGate

[![CI](https://github.com/usedhonda/clawgate/actions/workflows/ci.yml/badge.svg)](https://github.com/usedhonda/clawgate/actions/workflows/ci.yml)

A macOS menubar app that bridges local AI agents to native applications via Accessibility (AX) UI automation.

## What is ClawGate?

ClawGate is a lightweight macOS menubar-resident application that exposes a localhost-only HTTP API, allowing AI agents (such as [OpenClaw](https://github.com/usedhonda/openclaw_general)) to interact with native macOS apps that have no official API. It uses the macOS Accessibility framework to read UI state, send messages, detect inbound activity, and navigate application windows.

The first supported target is **LINE Desktop for Mac** (Qt-based), with full send/receive automation including hybrid inbound message detection. ClawGate also includes a **tmux adapter** for sending tasks to Claude Code sessions and monitoring their progress.

ClawGate is designed for privacy-first, single-user operation. It binds to `127.0.0.1` by default with no authentication required. Optional remote mode is available via settings (`0.0.0.0` bind + Bearer token).

## Key Features

- **LINE Send/Receive** -- Open conversations by name, send messages, read visible chat history
- **Hybrid Inbound Detection** -- Multi-signal fusion engine combining AX structure analysis, pixel diff, and notification banner monitoring for reliable message detection
- **Notification Banner Watcher** -- Event-driven detection via macOS notification center AX observer (no OCR needed for sender/message extraction)
- **Echo Suppression** -- Temporal-window-based filtering to distinguish self-sent messages from true inbound messages
- **Tmux / Claude Code Adapter** -- Monitor Claude Code sessions via cc-status-bar WebSocket, send tasks, auto-approve permissions, detect questions
- **4-Stage Session Modes** -- Per-project control: ignore, observe, auto, autonomous
- **OpenClaw Integration** -- Channel plugin for the OpenClaw AI gateway ecosystem
- **Privacy-First** -- Localhost by default, optional remote mode with token, no cloud relay dependency

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  macOS Menu Bar (NSStatusItem)                          │
│  ┌─────────────────┐  ┌──────────────────────────────┐  │
│  │ SettingsView     │  │ Sessions Submenu (Tmux)      │  │
│  └─────────────────┘  └──────────────────────────────┘  │
├─────────────────────────────────────────────────────────┤
│  BridgeServer (SwiftNIO HTTP/1.1 on 127.0.0.1:8765 by default) │
│  ┌──────────────────────────────────────────────────┐   │
│  │ BridgeCore: routing, validation, adapter dispatch │   │
│  │ EventBus: ring buffer (1000) + SSE streaming      │   │
│  │ ConfigStore: UserDefaults-backed configuration     │   │
│  └──────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────┤
│  Adapters                                               │
│  ┌────────────────────┐  ┌───────────────────────────┐  │
│  │ LINEAdapter        │  │ TmuxAdapter               │  │
│  │ - AX send/read     │  │ - CCStatusBarClient (WS)  │  │
│  │ - Vision OCR       │  │ - TmuxShell (CLI)         │  │
│  └────────────────────┘  └───────────────────────────┘  │
├─────────────────────────────────────────────────────────┤
│  Inbound Detection                                      │
│  ┌──────────────────┐ ┌────────────┐ ┌───────────────┐  │
│  │ NotificationBanner│ │ LINEInbound│ │ TmuxInbound   │  │
│  │ Watcher (primary) │ │ Watcher    │ │ Watcher       │  │
│  └──────────────────┘ └────────────┘ └───────────────┘  │
├─────────────────────────────────────────────────────────┤
│  Automation Layer                                       │
│  AXQuery / AXActions / AXDump / SelectorResolver        │
│  VisionOCR / RetryPolicy / GeometryHint                 │
└─────────────────────────────────────────────────────────┘
```

## Requirements

- **macOS 12+** (Monterey or later)
- **Swift 5.9+** (SwiftPM, swift-nio 2.67+)
- **LINE Desktop for Mac** (for LINE adapter)
- **cc-status-bar** (for tmux adapter -- provides session state via WebSocket)
- **Xcode** (for `swift test`; `swift build` works with CommandLineTools only)

## Permissions

| Permission | Required For | How to Grant |
|------------|-------------|--------------|
| Accessibility | All AX endpoints (send, context, messages, conversations, axdump, doctor) | System Settings > Privacy & Security > Accessibility |
| Screen Recording | Vision OCR for inbound message text extraction | System Settings > Privacy & Security > Screen Recording |

## Quick Start

1. **Clone and build**:
   ```bash
   git clone https://github.com/usedhonda/clawgate.git
   cd clawgate
   swift build
   ```

2. **Set up signing certificate** (one-time):
   ```bash
   ./scripts/setup-cert.sh
   ```

3. **Deploy**:
   ```bash
   ./scripts/dev-deploy.sh
   ```

4. **Grant Accessibility permission** in System Settings when prompted.

5. **Verify**:
   ```bash
   curl -s http://127.0.0.1:8765/v1/doctor | jq .
   ```

## API Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/v1/health` | Health check (returns version) |
| GET | `/v1/doctor` | System diagnostics (AX permission, LINE status, etc.) |
| GET | `/v1/config` | Current configuration (general, LINE, tmux settings) |
| GET | `/v1/poll[?since=N]` | Poll buffered events (long-polling compatible) |
| GET | `/v1/events` | SSE stream of real-time events |
| GET | `/v1/context[?adapter=line]` | Current conversation context |
| GET | `/v1/messages[?adapter=line&limit=50]` | Visible messages in active chat |
| GET | `/v1/conversations[?adapter=line&limit=50]` | Conversation list with unread status |
| GET | `/v1/axdump[?adapter=line]` | Raw AX tree dump (debugging) |
| POST | `/v1/send` | Send a message via adapter |

All endpoints return JSON. In local mode no authentication is required. In remote mode, `Authorization: Bearer <token>` is required.
POST requests with an `Origin` header are rejected (CSRF protection).

See [SPEC.md](SPEC.md) for full API documentation.

## Build & Deploy

```bash
# Full pipeline: build + deploy + plugin sync + smoke test (preferred)
./scripts/dev-deploy.sh

# ClawGate only (skip OpenClaw plugin sync)
./scripts/dev-deploy.sh --skip-plugin

# Deploy without smoke test
./scripts/dev-deploy.sh --skip-test

# Smoke test (5 tests, ~5s)
./scripts/smoke-test.sh

# Full integration test suite
./scripts/integration-test.sh

# Release build (universal binary + DMG + notarize)
./scripts/release.sh

# Remote relay (Phase 3 foundation)
swift run ClawGateRelay \
  --host 0.0.0.0 \
  --port 8765 \
  --federation-port 8766 \
  --token YOUR_GATEWAY_TOKEN \
  --federation-token YOUR_FEDERATION_TOKEN \
  --cc-status-url ws://localhost:8080/ws/sessions \
  --tmux-mode project-a=autonomous \
  --tmux-mode project-b=observe

# Host A ClawGate federation URL
# ws://<HOST_B_IP>:8766/federation
```

## Configuration

ClawGate stores configuration in UserDefaults, accessible via `GET /v1/config`:

| Group | Keys | Description |
|-------|------|-------------|
| **General** | `nodeRole`, `debugLogging`, `includeMessageBodyInLogs` | Node role (`server`/`client`) and logging |
| **LINE** | `defaultConversation`, `pollIntervalSeconds`, `detectionMode`, `fusionThreshold`, signal enables | Detection and polling settings |
| **Tmux** | `enabled`, `statusBarUrl`, `sessionModes` | Claude Code session monitoring |

See [SPEC.md](SPEC.md) for the full configuration schema.

## Project Structure

```
ClawGate/
  main.swift                              # App entry point, NSApplication setup
ClawGateRelay/
  main.swift                              # Remote relay HTTP + federation WebSocket server
  Adapters/
    AdapterProtocol.swift                 # AdapterProtocol + AdapterRegistry
    LINE/
      LINEAdapter.swift                   # LINE AX automation (send, read)
      LINEInboundWatcher.swift            # AX polling for inbound detection
      NotificationBannerWatcher.swift     # Event-driven banner detection
      LineSelectors.swift                 # Selector definitions for LINE UI
      Detection/
        LineDetectionTypes.swift          # Signal/Decision types
        LineDetectionFusionEngine.swift   # Multi-signal fusion scoring
    Tmux/
      TmuxAdapter.swift                   # Claude Code task dispatch
      TmuxInboundWatcher.swift            # State transition detection
      CCStatusBarClient.swift             # WebSocket client for cc-status-bar
      TmuxShell.swift                     # tmux CLI wrapper
  Automation/
    AX/                                   # AXUIElement query, actions, dump
    Selectors/                            # Multi-layer UI element scoring
    Retry/                                # Exponential backoff
    Vision/                               # VisionOCR (screen capture + text)
  Core/
    BridgeServer/                         # NIO HTTP server, routing, models
    Config/                               # UserDefaults-backed ConfigStore
    EventBus/                             # Ring buffer + SSE + RecentSendTracker
    Logging/                              # AppLogger + StepLog
  UI/                                     # MenuBarApp, SettingsView
Tests/
  UnitTests/                              # 8 test files
scripts/
  dev-deploy.sh                           # Build + deploy + smoke test
  smoke-test.sh                           # Quick validation (5 tests)
  integration-test.sh                     # Full API test suite
  release.sh                              # Universal build + DMG + notarize
  setup-cert.sh                           # Self-signed certificate setup
extensions/
  openclaw-plugin/                        # OpenClaw channel plugin (JS/ESM)
  vibeterm-telemetry/                     # Location telemetry plugin (JS/ESM)
```

## See Also

- [SPEC.md](SPEC.md) -- Full technical specification (API, threading, events, selectors)
- [docs/architecture.md](docs/architecture.md) -- Architecture overview
- [docs/troubleshooting.md](docs/troubleshooting.md) -- Known issues and fixes
- [AGENTS.md](AGENTS.md) -- Product requirements and design goals
