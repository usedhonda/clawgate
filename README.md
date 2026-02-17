# ClawGate

[![CI](https://github.com/usedhonda/clawgate/actions/workflows/ci.yml/badge.svg)](https://github.com/usedhonda/clawgate/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A macOS menu bar app that lets an AI agent (OpenClaw) monitor, review, and interact with your Claude Code / Codex sessions in real time.

## How It Works

```
Claude Code (tmux) <--WS--> cc-status-bar <--WS--> ClawGate <--HTTP--> OpenClaw Gateway <--> AI
                                                       |                                     |
                                                   EventBus                            User (LINE/etc)
                                                   HTTP API
```

1. **cc-status-bar** connects to Claude Code / Codex tmux sessions and streams state changes over WebSocket
2. **ClawGate** receives those events, buffers them in an EventBus (ring buffer, 1000 events), and exposes them via HTTP API (`/v1/poll`, `/v1/events` SSE)
3. **OpenClaw plugin** polls ClawGate for events, sends task completions and questions to an AI for review
4. The AI responds with `<cc_task>` tags that ClawGate sends back to Claude Code / Codex via tmux

## Installation

### Download

Download the latest DMG from [GitHub Releases](https://github.com/usedhonda/clawgate/releases/latest).

### Install

1. Open `ClawGate.dmg` and drag **ClawGate** to **Applications**
2. Launch ClawGate from Applications (it runs as a menu bar app)
3. Grant **Accessibility** permission when prompted (System Settings > Privacy & Security > Accessibility)
4. Install [cc-status-bar](https://github.com/nicobailon/cc-status-bar) and start it:
   ```bash
   cc-status-bar
   ```
5. Verify ClawGate is running:
   ```bash
   curl -s http://127.0.0.1:8765/v1/health | python3 -m json.tool
   # Full diagnostics
   curl -s http://127.0.0.1:8765/v1/doctor | python3 -m json.tool
   ```

### Requirements

- macOS 13+ (Ventura or later)
- [cc-status-bar](https://github.com/nicobailon/cc-status-bar) (provides Claude Code / Codex session state via WebSocket)

## Session Modes

Each tmux project can be assigned one of four session modes. Set them in the menu bar: **ClawGate icon > Sessions > (project) > Mode**.

| Mode | Monitoring | AI -> CC Send | Use Case |
|------|-----------|---------------|----------|
| **ignore** | Off | Off | Default. ClawGate does nothing for this project |
| **observe** | On | Off | AI reviews and reports to the user only (via LINE, etc.) |
| **auto** | On | Yes (auto-continue) | Quality gate. AI reviews; if OK, sends continue. No deep questions |
| **autonomous** | On | Yes (questions) | AI actively reviews, asks clarifying questions to CC, drills deeper |

- Mode changes take effect immediately (stored in UserDefaults, no restart needed)
- Modes are per-project: `cc:project-name` or `codex:project-name` as keys

## OpenClaw Integration

ClawGate includes an [OpenClaw](https://github.com/usedhonda/openclaw_general) channel plugin that connects the event stream to an AI reviewer.

### Plugin Setup

The plugin lives in `extensions/openclaw-plugin/` and should be symlinked or copied to the OpenClaw extensions directory:

```bash
# Copy plugin to OpenClaw
cp -r extensions/openclaw-plugin/ ~/.openclaw/extensions/clawgate/
# Or symlink
ln -s "$(pwd)/extensions/openclaw-plugin" ~/.openclaw/extensions/clawgate
```

### Configuration

The plugin reads ClawGate's config via `/v1/openclaw-info`. Key settings in the OpenClaw account config:

| Key | Default | Description |
|-----|---------|-------------|
| `apiUrl` | `http://127.0.0.1:8765` | ClawGate HTTP API base URL |
| `pollIntervalMs` | `3000` | Event polling interval in milliseconds |

### Prompt Customization

The plugin uses two prompt files:

| File | Purpose | Git Tracked |
|------|---------|-------------|
| `prompts.js` | Default review prompts (English, channel-agnostic) | Yes |
| `prompts-local.js` | Personal overrides (your language, channel-specific) | No (.gitignore) |

`prompts-local.js` is loaded first and merged over `prompts.js`. Use it for locale-specific prompts or personal workflow preferences.

### How `<cc_task>` and `<cc_answer>` Work

When the AI reviewer wants to interact with a Claude Code / Codex session, it embeds special XML tags in its response:

```xml
<!-- Send a task/message to Claude Code -->
<cc_task>Review the error handling in auth.ts</cc_task>

<!-- Auto-select an option in an AskUserQuestion menu (0-based index) -->
<cc_answer project="myproject">0</cc_answer>
```

ClawGate extracts these tags and dispatches them:
- `<cc_task>` content is sent to the tmux pane via `/v1/send`, prefixed with `[OpenClaw Agent - {Mode}]`
- `<cc_answer>` sends a `__cc_select:{index}` command to auto-select options

## Writing CLAUDE.md Rules

To get the most out of ClawGate + OpenClaw, add rules to your project's `CLAUDE.md` that tell Claude Code how to handle AI reviewer messages:

```markdown
## OpenClaw Agent Integration

Messages with `[OpenClaw Agent - {Mode}]` prefix are from your AI pair
reviewer, authorized via ClawGate session mode settings.

| Prefix | Reviewer Role | Your Response |
|--------|--------------|---------------|
| `[OpenClaw Agent - Auto]` | Quality gate (no judgment) | Work autonomously. Don't ask reviewer questions |
| `[OpenClaw Agent - Autonomous]` | Code reviewer (asks questions) | Answer their questions, continue working |
| `[OpenClaw Agent - Observe]` | Silent observer | Reviewer doesn't talk to you; ignore |
```

### Tips

- In **auto** mode, the reviewer checks task completions and auto-continues if things look good. Claude Code should treat `[OpenClaw Agent - Auto]` messages as directives and keep working
- In **autonomous** mode, the reviewer may ask "Why this approach?" or "What about edge case X?". Claude Code should answer concisely and continue
- Don't reference context window usage or token counts in responses to the reviewer -- it's noise

## API Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/v1/health` | Liveness check (returns version) |
| GET | `/v1/doctor` | System diagnostics (AX, adapters, federation) |
| GET | `/v1/config` | Current configuration |
| GET | `/v1/poll[?since=N]` | Cursor-based event polling |
| GET | `/v1/events` | SSE event stream (supports `Last-Event-ID` replay) |
| GET | `/v1/context[?adapter=tmux]` | Current conversation context |
| GET | `/v1/messages[?adapter=tmux&limit=50]` | Recent messages |
| GET | `/v1/conversations[?adapter=tmux&limit=50]` | Session/conversation list |
| GET | `/v1/stats` | Day stats and history |
| GET | `/v1/openclaw-info` | OpenClaw gateway config |
| GET | `/v1/axdump[?adapter=line]` | Raw AX tree dump (debug) |
| POST | `/v1/send` | Send a message/task via adapter |

All endpoints return JSON (`{"ok": true, "result": {...}}` or `{"ok": false, "error": {...}}`).
Local mode requires no authentication. Remote mode requires `Authorization: Bearer <token>`.
POST requests with an `Origin` header are rejected (CSRF protection).

See [SPEC.md](SPEC.md) for full API documentation.

## Building from Source

```bash
# Clone
git clone https://github.com/usedhonda/clawgate.git
cd clawgate

# Build
swift build

# Set up signing certificate (one-time)
./scripts/setup-cert.sh

# Deploy locally (build + sign + launch + smoke test)
./scripts/dev-deploy.sh

# Grant Accessibility permission when prompted

# Smoke test (5 tests, ~5s)
./scripts/smoke-test.sh

# Full integration test suite
./scripts/integration-test.sh
```

### Requirements

- macOS 12+ (Monterey or later)
- Swift 5.9+ (swift-nio 2.67+)
- Xcode or Command Line Tools

## Permissions

| Permission | Required For | How to Grant |
|------------|-------------|--------------|
| Accessibility | All AX endpoints, tmux adapter, LINE adapter | System Settings > Privacy & Security > Accessibility |
| Screen Recording | Vision OCR (LINE inbound text extraction) | System Settings > Privacy & Security > Screen Recording |

## Advanced: LINE Integration

> **This section is for users running ClawGate on a host with LINE Desktop installed (typically Host A in a 2-host setup).**

### Prerequisites

- [LINE Desktop for Mac](https://apps.apple.com/app/line/id539883307) (Qt-based)
- **Screen Recording** permission (for Vision OCR)

### How It Works

ClawGate automates LINE Desktop via the macOS Accessibility framework:

- **Send**: Opens conversations by name, types and sends messages via AX actions
- **Receive**: Hybrid inbound detection combining notification banner monitoring, AX structure analysis, and pixel diff
- **Echo Suppression**: Temporal-window filtering to distinguish self-sent messages from inbound

### Server Mode (Remote Access)

To expose ClawGate's API to other hosts (e.g., for Federation):

1. Enable remote access in Settings (`remoteAccessEnabled = true`)
2. Set a Bearer token (`remoteAccessToken`)
3. ClawGate binds to `0.0.0.0:8765` instead of `127.0.0.1`
4. All requests require `Authorization: Bearer <token>`

### LINE Recovery

```bash
# Regular recovery (Host A)
./scripts/line-fast-recover.sh --remote-host macmini

# Re-sign binary (when TCC permission is lost)
KEYCHAIN_PASSWORD='your-password' ./scripts/macmini-local-sign-and-restart.sh
```

## Advanced: Federation (2-Host Setup)

Federation connects two ClawGate instances over WebSocket, enabling a workstation (Host B) to relay events through a server (Host A) that has LINE and OpenClaw Gateway.

```
Host A (macmini)                 Host B (workstation)
+-----------------------+        +-----------------------+
| ClawGate (server)     |<--WS-->| ClawGate (client)     |
| - LINE adapter        | /fed   | - tmux adapter        |
| - Federation server   |  eration| - Federation client   |
| - OpenClaw Gateway    |        | - CC / Codex sessions |
+-----------------------+        +-----------------------+
```

### Configuration

**Host A** (server):
| Key | Value |
|-----|-------|
| `nodeRole` | `server` |
| `remoteAccessEnabled` | `true` |
| `remoteAccessToken` | `<token>` |

**Host B** (client):
| Key | Value |
|-----|-------|
| `nodeRole` | `client` |
| `federationEnabled` | `true` |
| `federationURL` | `ws://macmini:8765/federation` |
| `federationToken` | `<token>` |

### Mode Resolution

When a federation event arrives at Host A, the mode is resolved as:

1. **Server's local config** for that project (if set) -- highest priority
2. **Event's mode field** sent by the client -- used if server has no config
3. **`ignore`** -- fallback default

## Configuration Reference

ClawGate stores all configuration in UserDefaults, readable via `GET /v1/config`.

### General

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `nodeRole` | String | `"standalone"` | `standalone`, `server`, or `client` |
| `debugLogging` | Bool | `false` | Verbose logging |
| `includeMessageBodyInLogs` | Bool | `false` | Include message text in logs |
| `remoteAccessEnabled` | Bool | `false` | Bind to `0.0.0.0` instead of `127.0.0.1` |
| `remoteAccessToken` | String | `""` | Bearer token for remote access |

### Tmux

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `tmux.enabled` | Bool | `false` | Enable tmux adapter |
| `tmux.statusBarUrl` | String | `ws://localhost:8080/ws/sessions` | cc-status-bar WebSocket URL |
| `tmux.sessionModes` | Dict | `{}` | Per-project mode map (e.g., `{"cc:myproject": "autonomous"}`) |

### LINE

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `line.default_conversation` | String | `""` | Default LINE chat name |
| `line.poll_interval_seconds` | Int | `2` | Polling interval (seconds) |
| `line.detection_mode` | String | `"hybrid"` | `"legacy"` or `"hybrid"` |
| `line.fusion_threshold` | Int | `60` | Detection score threshold (1-100) |

### Federation

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `federationEnabled` | Bool | `false` | Enable federation client |
| `federationURL` | String | `""` | Server WebSocket URL |
| `federationToken` | String | `""` | Bearer auth token |
| `federationReconnectMaxSeconds` | Int | `120` | Max reconnect backoff (seconds) |

## Project Structure

```
ClawGate/
  main.swift                              # App entry point
  Adapters/
    LINE/
      LINEAdapter.swift                   # LINE AX automation (send, read)
      LINEInboundWatcher.swift            # AX polling for inbound detection
      NotificationBannerWatcher.swift     # Event-driven banner detection
      Detection/                          # Multi-signal fusion engine
    Tmux/
      TmuxAdapter.swift                   # Claude Code/Codex task dispatch
      TmuxInboundWatcher.swift            # State transition detection
      CCStatusBarClient.swift             # WebSocket client for cc-status-bar
      TmuxShell.swift                     # tmux CLI wrapper
  Automation/
    AX/                                   # AXUIElement query, actions, dump
    Selectors/                            # Multi-layer UI element scoring
    Vision/                               # VisionOCR (screen capture + text)
  Core/
    BridgeServer/                         # SwiftNIO HTTP server + routing
    Config/                               # UserDefaults-backed ConfigStore
    EventBus/                             # Ring buffer + SSE + polling
    Federation/                           # WebSocket federation (server + client)
    Logging/                              # AppLogger
  UI/                                     # MenuBarApp, SettingsView
ClawGateRelay/                            # DEPRECATED (replaced by Direct Federation)
Tests/
  UnitTests/                              # Unit tests
scripts/
  dev-deploy.sh                           # Build + sign + deploy + smoke test
  smoke-test.sh                           # Quick validation (5 tests)
  integration-test.sh                     # Full API test suite
  release.sh                              # Universal build + notarize + manifest (+ optional publish)
  release-usual.sh                        # Canonical release entrypoint (loads .local/secrets/release.env)
  support-diagnostics.sh                  # Support bundle generator (health/doctor/log/process)
  setup-cert.sh                           # Self-signed certificate setup
  post-task-restart.sh                    # Full deploy to Host A + Host B
extensions/
  openclaw-plugin/                        # OpenClaw channel plugin (JS/ESM)
```

## Release (Maintainers)

`scripts/release.sh` uses env-based credentials only.
Use `scripts/release-usual.sh` as the canonical entrypoint so credentials are loaded consistently.

Required environment variables:

- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_ID_PASSWORD`
- `SIGNING_ID`

Commands:

```bash
# Build + sign + notarize + staple + spctl + manifest
./scripts/release-usual.sh

# Same as above, then publish GitHub release
./scripts/release-usual.sh --publish --notes-file docs/release/release-notes.md
```

Release notes template:

```text
docs/release/release-notes-template.md
```

## See Also

- [SPEC.md](SPEC.md) -- Full API specification (endpoints, threading, events, selectors)
- [SPEC-messaging.md](docs/SPEC-messaging.md) -- Messaging protocol and federation spec
