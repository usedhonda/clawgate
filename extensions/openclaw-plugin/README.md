# ClawGate Channel Plugin for OpenClaw

Connects OpenClaw to a local ClawGate app so AI agents can review tmux/Codex sessions and send LINE messages through the ClawGate HTTP bridge.

## What this plugin adds

- Registers the `clawgate` channel in OpenClaw
- Reads account settings from OpenClaw and runtime preferences from ClawGate via `/v1/config`
- Sends outbound messages through ClawGate (`/v1/send`)
- Translates OpenClaw review output (`<cc_task>`, `<cc_answer>`) into tmux / messenger actions

## What works without OpenClaw

ClawGate itself is useful without this plugin. Users can still:

- run the macOS menu bar app
- monitor Claude Code / Codex tmux sessions
- use the local HTTP API (`/v1/health`, `/v1/poll`, `/v1/tmux/session-mode`, etc.)
- use LINE adapter / federation features directly from ClawGate

## What requires OpenClaw

The following features require OpenClaw plus this plugin:

- AI review of tmux session completions and questions
- autonomous / observe / auto review loops
- `<cc_task>` and `<cc_answer>` dispatch back into tmux sessions
- Telegram / LINE development-session notifications driven by OpenClaw

## Requirements

- Node.js in the OpenClaw v2026.11.1 engine range: `>=24.16.0 <25 || >=26.1.0`
- A running ClawGate instance reachable from OpenClaw (default: `http://127.0.0.1:8765`)
- OpenClaw installed and configured. The source-reviewed baseline is **v2026.11.1**; see [compatibility and upgrade limits](../../docs/openclaw-compatibility.md) before changing the host version. Some optional workflows require a separately maintained host extension.

## Install

### 1. Copy the plugin into OpenClaw

```bash
cp -R extensions/openclaw-plugin/ ~/.openclaw/extensions/clawgate/
```

Or symlink it during local development:

```bash
ln -s "$(pwd)/extensions/openclaw-plugin" ~/.openclaw/extensions/clawgate
```

### 2. Enable it in `~/.openclaw/openclaw.json`

```json
{
  "plugins": {
    "entries": {
      "clawgate": {
        "enabled": true
      }
    }
  },
  "channels": {
    "clawgate": {
      "default": {
        "apiUrl": "http://127.0.0.1:8765",
        "defaultConversation": "Your conversation"
      }
    }
  }
}
```

### 3. Restart OpenClaw gateway

Use the restart procedure for your installation. Repository-managed deployments must follow [AGENTS.md](../../AGENTS.md) and the project restart scripts. For a standalone OpenClaw service:

```bash
openclaw gateway stop
openclaw gateway start
```

## Configuration

Account configuration belongs under `channels.clawgate.<accountId>` in OpenClaw. ClawGate Settings provides additional runtime preferences through `/v1/config`. The main account fields are:

| Field | Example | Meaning |
|------|---------|---------|
| `apiUrl` | `http://127.0.0.1:8765` | ClawGate base URL |
| `token` | `...` | Optional Authorization header for an authenticated proxy or custom bridge |
| `defaultConversation` | `Your Name` | Default LINE conversation hint |
| `prompts.localOverlayPath` | `src/prompts-local.js` | Repo-local prompt overlay (optional) |
| `prompts.privateOverlayPath` | `~/.clawgate/prompts-private.js` | Machine-local private overlay (recommended) |

Notes:

- The native ClawGate bridge listens on all interfaces and applies source-address and browser-origin checks. The account `token` does **not** authenticate requests to that native bridge. Configure host firewall and tailnet access controls as described in the [main README](../../README.md).
- Set `token` only if an explicitly configured proxy or custom bridge verifies that header. Do not expose the native bridge directly to an untrusted network.
- The OpenClaw Gateway credential is a separate credential for ClawGate’s native WebSocket client. Do not copy it into this account field merely to configure a remote bridge.

## Prompt customization

Files in this plugin:

| File | Role | Distributed |
|------|------|-------------|
| `src/prompts.js` | Default shared prompts | Yes |
| `src/prompts-local.js.example` | Example repo-local overlay | Yes |
| `src/prompts-private.js.example` | Example private overlay | Yes |

Recommended workflow:

1. Keep `src/prompts.js` as the shared default.
2. Copy `src/prompts-private.js.example` to `~/.clawgate/prompts-private.js` for personal tone changes.
3. Use a repo-local overlay only when you intentionally want repository-scoped overrides.

## Verify

```bash
node --check extensions/openclaw-plugin/index.js
node --check extensions/openclaw-plugin/src/gateway.js
node --experimental-test-module-mocks --test extensions/openclaw-plugin/src/__tests__/*.test.js
```

## Related files

| File | Purpose |
|------|---------|
| `openclaw.plugin.json` | Plugin manifest |
| `index.js` | Plugin entry point |
| `src/channel.js` | Channel registration |
| `src/gateway.js` | Review loop / messaging orchestration |
| `src/outbound.js` | ClawGate outbound transport |
| `src/client.js` | HTTP client for ClawGate |
