# OpenClaw directory adapter implementation

**Date**: 2026-02-08
**Task**: Fix "Unknown target" error when using `message send --target "Yuzuru Honda"`

## Problem

OpenClaw target-resolver calls `plugin.directory.listPeers()` to resolve target names.
ClawGate plugin had no `directory` adapter, so `listPeers()` returned `[]`,
causing `resolveMatch()` -> `"none"` -> `unknownTargetError()`.

## Solution

Two-layer directory adapter:

1. **Config layer** (always available): `defaultConversation` from `openclaw.json`
   - Works even when LINE is in background (AX tree unavailable)
   - `rank: 100` for priority in ambiguous matches
2. **Live layer** (foreground only): `GET /v1/conversations` from ClawGate API
   - Additional targets available when LINE window is visible

## Changed files

1. `extensions/openclaw-plugin/src/client.js:82-91` — added `clawgateConversations()`
2. `extensions/openclaw-plugin/src/directory.js` — new file, `listPeers` implementation
3. `extensions/openclaw-plugin/src/channel.js:8,69` — import + export `directory`

## Verification

- Build: OK
- Smoke test: 5/5 PASS
- OpenClaw gateway: doctor OK, polling started, no load errors
- Plugin loaded with `defaultConv="Yuzuru Honda"` confirmed in logs
