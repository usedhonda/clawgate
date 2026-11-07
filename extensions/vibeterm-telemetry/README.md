# Vibeterm Telemetry — OpenClaw Plugin

Receives batched location samples from the Vibeterm iOS app and writes them to
daily diary files for AI location awareness.

**Flow:** iOS background location → `POST /api/telemetry` → in-memory store + diary file

## Files

| File | Role |
|------|------|
| `index.js` | Plugin entry — registers HTTP route |
| `src/handler.js` | Request handler — validation, dedup, serialized diary write |
| `src/request-body.js` | Bounded body read — byte limit, deadline and abort cleanup |
| `src/validation.js` | Location and health input validation before diary rendering |
| `src/store.js` | In-memory store — UUID dedup (1h TTL, max 10,000), history (100 entries) |
| `openclaw.plugin.json` | Plugin manifest (required by OpenClaw) |

## Diary Writing

Location samples are written to `~/.openclaw/workspace/memory/YYYY-MM-DD.md`.

- **Format:** `📍 HH:MM - lat, lon (accuracy Xm)`
- **Timezone:** UTC, with an explicit `Z` suffix
- **Throttle:** 200m+ movement or 30min+ elapsed (~5-20 entries/day)
- **Errors:** Logged but never affect the API response
- **New files:** owner-only permissions (`0600`, new memory directories `0700`)

The AI reads these diary files at session start to understand the user's location context.

## Authentication and limits

The exact `/api/telemetry` route declares `auth: "gateway"`. OpenClaw performs
authentication before invoking the handler, using its resolved auth policy;
the plugin does not cache or compare a plaintext token from `api.config`.
This preserves environment-provided credentials, SecretRefs, password mode,
and credential rotation. Deploy it with authenticated Gateway access. An
explicit `gateway.auth.mode: "none"` is an operator opt-out and also leaves
Gateway-auth routes unauthenticated.

OpenClaw `v2026.11.1` requires an explicit route auth field; the prior registration
without one is rejected by that host. See the tagged
[route registrar](https://github.com/openclaw/openclaw/blob/v2026.11.1/src/plugins/registry-registrars-network.ts)
and [HTTP route contract](https://docs.openclaw.ai/plugins/architecture-internals/gateway-routes).

Each body is limited to 1 MiB, 10 seconds, and 1,000 samples. At most eight
requests are admitted concurrently; excess requests receive `503` with
`Retry-After: 1`. `413` means the sender must split the batch; `408` means the
upload did not complete in time. Invalid location samples are skipped; invalid
health summaries receive `400` before any samples from that body are stored.
Raw invalid samples are never logged. Health numbers must be finite numbers,
timestamps must parse, and workout names cannot contain line breaks.

Diary processing is serialized so simultaneous batches respect the existing
200 m / 30-minute throttle. The dedup cache expires on access without a
background timer and evicts its oldest ID if it reaches 10,000 entries. Normal
one-hour retry deduplication is preserved below that capacity.

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

## Test

Deterministic regressions (no live Gateway, location transmission, or real diary):

```bash
node --test extensions/vibeterm-telemetry/src/__tests__/*.test.js
```

For live acceptance, use an isolated development Gateway and synthetic samples
with a current timestamp. First confirm that invalid credentials are rejected by
the Gateway, then verify one accepted batch and a duplicate batch using that
Gateway's configured authentication method. Check only the isolated development
diary. Do not replay historical location records into a production diary.

The unit suite verifies the route registration contract and handler behavior;
it does not substitute for Gateway authentication and plugin lifecycle testing
on the exact host release being deployed.
