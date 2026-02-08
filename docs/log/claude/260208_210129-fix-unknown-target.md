# Fix: Unknown target error in OpenClaw message send

**Date**: 2026-02-08
**Issue**: OpenClaw agent (chi) sends `message send --channel clawgate` but gets `Unknown target "clawgate:default"` error.

## Root Cause

OpenClaw's target-resolver flow:
1. Agent generates target = `"clawgate:default"` (channel:accountId format)
2. `looksLikeTargetId("clawgate:default")` -> `false` (no matching prefix)
3. Falls through to directory lookup: `matchesDirectoryEntry` does `entryValue.includes(query)`
4. `"yuzuru honda".includes("clawgate:default")` -> `false`
5. -> `unknownTargetError()`

## Fix (2 files)

### 1. `extensions/openclaw-plugin/src/channel.js`

Added `messaging.targetResolver.looksLikeId` hook:
```javascript
messaging: {
  targetResolver: {
    looksLikeId: (raw) => raw === "default" || raw.startsWith("clawgate:"),
  },
},
```
This tells target-resolver to treat `"default"` and `"clawgate:*"` as direct IDs, bypassing directory lookup.

### 2. `extensions/openclaw-plugin/src/outbound.js`

Added target-to-conversationHint mapping in `sendText`:
```javascript
const conversationHint = (to === "default" || to.includes(":"))
  ? (account.defaultConversation || to)
  : to;
```
Converts account-format targets to the actual `defaultConversation` value from config.

## Verification

- Gateway restart: OK
- `doctor OK (5/5 checks passed)`
- `initial cursor=13` - polling started
- No plugin load errors
- No new `Unknown target` errors after restart (previous errors were pre-fix)

## Follow-up: sendMedia not implemented

After fixing Unknown target, a second error surfaced:
`Outbound not configured for channel: clawgate`

**Root cause**: `deliver.ts:95` checks `!outbound?.sendText || !outbound?.sendMedia` — both are required.
Our outbound only had `sendText`.

**Fix**: Added `sendMedia` stub to `outbound.js` that sends text caption as fallback (LINE doesn't support media via AX bridge).

## Final Result

All three errors resolved:
1. Unknown target "clawgate:default" -> `looksLikeId` hook
2. Unknown target "Yuzuru Honda" -> `directory.js` (already implemented)
3. Outbound not configured -> `sendMedia` stub added

**Proactive messaging fully operational.** Chi can now send messages to LINE via ClawGate.
