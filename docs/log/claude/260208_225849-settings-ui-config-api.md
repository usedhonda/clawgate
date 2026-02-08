# Settings UI + Config API

**Date:** 2026-02-08
**Task:** Settings UI にLINE設定を追加、GET /v1/config API エンドポイント追加、OpenClaw plugin で config fallback

## Changes

### ClawGate (Swift)

| File | Changes |
|------|---------|
| `ClawGate/Core/Config/AppConfig.swift` | Added `lineDefaultConversation`, renamed `pollIntervalSeconds` -> `linePollIntervalSeconds` with migration from legacy key |
| `ClawGate/Core/BridgeServer/BridgeModels.swift` | Added `ConfigGeneralSection`, `ConfigLineSection`, `ConfigResult` models |
| `ClawGate/Core/BridgeServer/BridgeCore.swift` | Added `configStore` property, `config()` method returning ConfigResult |
| `ClawGate/Core/BridgeServer/BridgeRequestHandler.swift` | Added `GET /v1/config` route (responds on event loop, no AX needed) |
| `ClawGate/main.swift` | Pass `configStore` to BridgeCore init, use `linePollIntervalSeconds` |
| `ClawGate/UI/SettingsView.swift` | Sectioned into General/LINE with GroupBox, added TextField for defaultConversation |

### OpenClaw Plugin (JavaScript)

| File | Changes |
|------|---------|
| `extensions/openclaw-plugin/src/client.js` | Added `clawgateConfig()` function |
| `extensions/openclaw-plugin/src/gateway.js` | Fetch `/v1/config` at startup, fallback chain for defaultConversation and pollIntervalMs |
| `extensions/openclaw-plugin/src/config.js` | Updated comments to reflect minimal config |

## Config API Response

```json
GET /v1/config
{
  "ok": true,
  "result": {
    "version": "0.1.0",
    "general": { "debugLogging": true, "includeMessageBodyInLogs": false },
    "line": { "defaultConversation": "Yuzuru Honda", "pollIntervalSeconds": 1 }
  }
}
```

## Fallback Chain (OpenClaw plugin)

```
openclaw.json defaultConversation (explicit, highest priority)
  -> ClawGate /v1/config line.defaultConversation
  -> "" (unset)
```

## Verification

- Build: OK (warnings only, pre-existing)
- Deploy: S1-S4 PASS
- /v1/config API: Returns correct values from UserDefaults
- OpenClaw gateway: doctor OK (5/5), polling started
- Settings UI: General/LINE sections with GroupBox, TextField for defaultConversation
