# OpenClaw Plugin — Dedup + Short Text Filter

**Date**: 2026-02-08
**Status**: Implemented and verified

## Changes

**File**: `extensions/openclaw-plugin/src/gateway.js`

### Added Functions
- `eventFingerprint(text)` — Normalize text (whitespace collapse + first 60 chars)
- `isDuplicateInbound(eventText)` — Sliding window (15s) dedup by fingerprint
- `recordInbound(eventText)` — Record event for dedup tracking

### Added Constants
- `DEDUP_WINDOW_MS = 15_000` — 15-second dedup window
- `MIN_TEXT_LENGTH = 5` — Minimum text length to process

### Filter Pipeline (polling loop)
```
① event.type !== "inbound_message" → skip (ClawGate echo)
② eventText.trim().length < 5 → skip (empty/short)
③ isPluginEcho(eventText) → skip (plugin echo suppression)
④ isDuplicateInbound(eventText) → skip (cross-source dedup)
⑤ recordInbound(eventText) — record before dispatch
⑥ handleInboundMessage() — AI dispatch
```

## Verification Results

| Filter | Events | Working |
|--------|--------|---------|
| Short text (0 chars) | 1 | YES — previously caused "I didn't receive any text" loop |
| Echo suppression | 4 | YES — AI replies caught by InboundWatcher suppressed |
| Duplicate dedup | 0 | Logic ready — no duplicate events observed yet |

## Known Remaining Issue

**OCR text quality**: PixelDiff source OCRs the entire visible chat area, not just the
new message. This means `payload.text` contains old messages + timestamps + "既読" etc.
This is a ClawGate Swift-side issue (InboundWatcher), not a plugin issue.

NotificationBanner source provides clean sender + text when a banner appears.

## Deploy

```bash
rm -rf ~/.openclaw/extensions/clawgate
cp -R extensions/openclaw-plugin ~/.openclaw/extensions/clawgate
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway
```
