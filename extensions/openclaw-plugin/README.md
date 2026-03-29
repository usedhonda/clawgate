# ClawGate Channel Plugin for OpenClaw

Connects OpenClaw to a local ClawGate app so AI agents can review tmux/Codex sessions and send LINE messages through the ClawGate HTTP bridge.

## What this plugin adds

- Registers the `clawgate` channel in OpenClaw
- Reads channel config from ClawGate via `/v1/openclaw-info`
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

- Node.js 18 or newer
- A running ClawGate instance reachable from OpenClaw (default: `http://127.0.0.1:8765`)
- OpenClaw installed and configured

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
  }
}
```

### 3. Restart OpenClaw gateway

```bash
openclaw gateway stop
openclaw gateway start
```

## Configuration

The plugin reads its runtime account config from ClawGate. The most important fields are:

| Field | Example | Meaning |
|------|---------|---------|
| `apiUrl` | `http://127.0.0.1:8765` | ClawGate base URL |
| `token` | `...` | Bearer token for remote ClawGate instances |
| `defaultConversation` | `Your Name` | Default LINE conversation hint |
| `prompts.localOverlayPath` | `src/prompts-local.js` | Repo-local prompt overlay (optional) |
| `prompts.privateOverlayPath` | `~/.clawgate/prompts-private.js` | Machine-local private overlay (recommended) |

Notes:

- Local ClawGate usually does not require a token.
- Remote ClawGate requires `Authorization: Bearer <token>`.
- The gateway token comes from your OpenClaw configuration (`~/.openclaw/openclaw.json`).

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
