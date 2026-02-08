# vibeterm-telemetry OpenClaw Plugin

**Date**: 2026-02-08
**Task**: Vibeterm iOS から位置情報を受け取る REST エンドポイントを OpenClaw プラグインとして実装

## Changes

### New Files
- `extensions/vibeterm-telemetry/package.json` — Plugin package metadata
- `extensions/vibeterm-telemetry/openclaw.plugin.json` — OpenClaw manifest (required for plugin discovery)
- `extensions/vibeterm-telemetry/index.js` — Plugin entry, registers `POST /api/telemetry` via `api.registerHttpRoute()`
- `extensions/vibeterm-telemetry/src/auth.js` — Bearer token verification against `api.config.gateway.auth.token`
- `extensions/vibeterm-telemetry/src/store.js` — In-memory location store with UUID dedup (1h TTL, 100-entry history buffer)
- `extensions/vibeterm-telemetry/src/handler.js` — Request handler: method check → auth → JSON parse → dedup → store → response

### Modified Files
- `scripts/dev-deploy.sh` — Refactored plugin sync to handle multiple plugins (clawgate + vibeterm-telemetry) with single gateway restart

## API Specification

```
POST /api/telemetry
Authorization: Bearer <gateway-auth-token>
Content-Type: application/json

Request:  { "samples": [{ "id": "uuid", "lat": 35.6, "lon": 139.6, "accuracy": 10.0, "timestamp": "ISO8601", ... }] }
Response: { "received": N, "nextMinIntervalSec": 60 }

Errors:
  401: { "error": { "code": "UNAUTHORIZED", "message": "..." } }
  400: { "error": { "code": "BAD_REQUEST", "message": "..." } }
  405: { "error": { "code": "METHOD_NOT_ALLOWED", "message": "..." } }
```

## Test Results (all PASS)

| Test | Expected | Result |
|------|----------|--------|
| Normal POST (1 sample) | received:1 | PASS |
| Auth error (invalid token) | 401 UNAUTHORIZED | PASS |
| Dedup (same UUID) | received:0 | PASS |
| Method not allowed (GET) | 405 | PASS |
| Bad JSON body | 400 | PASS |
| Batch (2 new + 1 dup) | received:2 | PASS |

## Lessons Learned

### openclaw.plugin.json is mandatory
- OpenClaw requires `openclaw.plugin.json` manifest for every plugin
- Without it, the gateway refuses to start (config validation fails in a loop)
- Minimal manifest: `{ "id": "plugin-id", "configSchema": { "type": "object", "additionalProperties": false, "properties": {} } }`
- The `configSchema` field is required even if the plugin has no config

### registerHttpRoute API
- Signature: `api.registerHttpRoute({ path: "/api/telemetry", handler: async (req, res) => {} })`
- Handler receives standard Node.js `IncomingMessage` and `ServerResponse`
- Path matching is exact pathname match (no wildcards)
- Gateway auth token accessible via `api.config.gateway?.auth?.token`

### Plugin config registration
- `openclaw.json` → `plugins.entries.vibeterm-telemetry.enabled = true`
- Must be registered in config AND have manifest file to be loaded

## OpenClaw State After Deploy
- clawgate: paired successfully, doctor OK, polling active (cursor=81)
- vibeterm-telemetry: registered POST /api/telemetry, all tests pass
