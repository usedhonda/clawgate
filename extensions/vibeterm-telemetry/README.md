# Vibeterm Telemetry — OpenClaw Plugin

Receives batched location samples from the Vibeterm iOS app and writes them to
daily diary files for AI location awareness.

**Flow:** iOS background location → `POST /api/telemetry` → in-memory store + diary file

## Files

| File | Role |
|------|------|
| `index.js` | Plugin entry — registers HTTP route |
| `src/handler.js` | Request handler — auth, parse, dedup, diary write |
| `src/store.js` | In-memory store — UUID dedup (1h TTL), circular history (100 entries) |
| `src/auth.js` | Bearer token validation against gateway token |
| `openclaw.plugin.json` | Plugin manifest (required by OpenClaw) |

## Diary Writing

Location samples are written to `~/.openclaw/workspace/memory/YYYY-MM-DD.md`.

- **Format:** `📍 HH:MM - lat, lon (accuracy Xm)`
- **Timezone:** JST (Asia/Tokyo)
- **Throttle:** 200m+ movement or 30min+ elapsed (~5-20 entries/day)
- **Errors:** Logged but never affect the API response

The AI reads these diary files at session start to understand the user's location context.

## Setup

### 1. Plugin manifest

`openclaw.plugin.json` must exist in the plugin directory:

```json
{
  "id": "vibeterm-telemetry",
  "configSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {}
  }
}
```

### 2. Register in openclaw.json

Add to `~/.openclaw/openclaw.json` under `plugins.entries`:

```json
{
  "plugins": {
    "entries": {
      "vibeterm-telemetry": {
        "enabled": true
      }
    }
  }
}
```

### 3. Deploy

```bash
# Copy plugin to OpenClaw extensions directory
cp -R extensions/vibeterm-telemetry/ ~/.openclaw/extensions/vibeterm-telemetry/

# Restart gateway
openclaw gateway stop && openclaw gateway start
```

Note: Symlinks are not supported by OpenClaw discovery — use `cp -R`.

## Test

```bash
# Get gateway auth token
TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/.openclaw/openclaw.json'))['gateway']['auth']['token'])")

# Send a test sample
curl -s -X POST http://localhost:18789/api/telemetry \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"samples":[{"id":"test-001","lat":35.6762,"lon":139.6503,"accuracy":10,"timestamp":"2026-01-01T00:00:00Z"}]}'

# Expected: {"received":1,"nextMinIntervalSec":60}

# Verify diary was written
cat ~/.openclaw/workspace/memory/2026-01-01.md
# Expected: 📍 09:00 - 35.6762, 139.6503 (accuracy 10m)
```
