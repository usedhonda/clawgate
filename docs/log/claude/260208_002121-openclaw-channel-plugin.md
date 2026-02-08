# OpenClaw Channel Plugin Implementation

**Date**: 2026-02-08
**Task**: Implement OpenClaw channel plugin for ClawGate

## Summary

Created a complete OpenClaw channel plugin that bridges LINE messaging via ClawGate.

## Architecture

```
LINE User ←→ LINE Desktop ←AX→ ClawGate (8765) ←HTTP→ OpenClaw Plugin ←→ OpenClaw AI Agent
```

## Files Created

| File | Purpose |
|------|---------|
| `extensions/openclaw-plugin/openclaw.plugin.json` | Plugin manifest |
| `extensions/openclaw-plugin/package.json` | ESM module declaration |
| `extensions/openclaw-plugin/index.js` | Plugin entry point (register) |
| `extensions/openclaw-plugin/src/channel.js` | ChannelPlugin definition |
| `extensions/openclaw-plugin/src/config.js` | Account config resolution |
| `extensions/openclaw-plugin/src/outbound.js` | Send messages (AI → LINE) |
| `extensions/openclaw-plugin/src/gateway.js` | Receive messages (LINE → AI) |
| `extensions/openclaw-plugin/src/client.js` | ClawGate HTTP client |

## Key Design Decisions

1. **Plain JavaScript (ESM)** — no TypeScript, no build step needed
2. **No external dependencies** — uses Node.js 22+ built-in `fetch()`
3. **Auto-pairing** — if token is empty, auto-pairs via pair/generate + pair/request
4. **Token persistence** — saves auto-paired token back to openclaw.json
5. **Polling** — uses /v1/poll?since=N with cursor tracking
6. **Echo suppression** — only processes `inbound_message` events (ClawGate already filters echo_message)
7. **Auto re-pair** — on 401 unauthorized, re-pairs automatically
8. **Runtime API access** — uses `api.runtime.channel.reply.createReplyDispatcherWithTyping` and `api.runtime.channel.reply.dispatchInboundMessage`

## Installation

```bash
# Symlink (already done)
ln -sf /Users/usedhonda/projects/Mac/clawgate/extensions/openclaw-plugin \
       ~/.openclaw/extensions/clawgate

# Config added to ~/.openclaw/openclaw.json channels.clawgate section
```

## OpenClaw Config

```json
{
  "channels": {
    "clawgate": {
      "default": {
        "enabled": true,
        "apiUrl": "http://127.0.0.1:8765",
        "token": "",
        "pollIntervalMs": 3000,
        "defaultConversation": "Yuzuru Honda"
      }
    }
  }
}
```

## Verification Steps

1. ClawGate health: `curl -s localhost:8765/v1/health` → OK
2. Symlink: `~/.openclaw/extensions/clawgate` → OK
3. Config: `channels.clawgate` section added → OK
4. Next: Restart OpenClaw gateway to load the plugin

## Notes

- The gateway.js uses runtime API methods which may have slightly different paths
  depending on OpenClaw version. The code tries multiple paths:
  - `runtime.channel.reply.dispatchInboundMessage`
  - `runtime.dispatch.dispatchInboundMessage`
- If neither is found, an error is logged
- DM policy is set to "open" (no pairing approval required)
