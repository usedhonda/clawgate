# CGEvent Click→Enter Pattern for Qt Apps

## Date: 2026-02-07

## Problem
LINE (Qt app) ignores CGEvent Enter and AppleScript `key code 36` because:
- `AXFocused=true` only sets AX-level focus, not Qt's internal first responder
- `app.activate()` foregrounds the app but doesn't establish keyboard focus on any specific Qt widget
- Physical keyboard Enter works, proving the issue is focus establishment, not key delivery

## Root Cause
Qt maintains its own focus system independent of macOS Accessibility. AX focus attributes
and NSRunningApplication activation don't trigger Qt's focus dispatching.

## Solution
Use CGEvent mouse click (`clickAt(point:)`) to physically click the target element,
which triggers Qt's native mouse event handling and establishes first responder.

### Changes

| File | Change |
|------|--------|
| `ClawGate/Automation/AX/AXActions.swift:36` | Added `clickAt(point:)` - CGEvent mouse down/up with `mouseEventSource: nil` |
| `ClawGate/Automation/AX/AXActions.swift:55` | Simplified `sendEnter()` - removed AppleScript cascade, CGEvent session tap only |
| `ClawGate/Automation/AX/AXActions.swift` | Removed `sendEnterViaSystemEvents()` and `confirmEnterFallback()` |
| `ClawGate/Adapters/LINE/LINEAdapter.swift:121-128` | open_conversation: click search field before Enter |
| `ClawGate/Adapters/LINE/LINEAdapter.swift:189-199` | send_message: click input field before Enter |
| `CLAUDE.md:45-47` | Updated pitfall documentation |

### Key Design Decisions
- `mouseEventSource: nil` = no source, treated as hardware-like event (maximizes Qt acceptance)
- `usleep(50_000)` between mouse down/up (50ms, realistic click timing)
- `Thread.sleep(0.15)` between click and Enter (allow Qt to process focus change)
- Removed AppleScript path entirely (NSAppleScript is not thread-safe, osascript is overhead)

## Verification
- `swift build` succeeded (warnings only: deprecated NSWorkspace API, pre-existing)
- Binary updated and re-signed
- Manual test pending: send message to LINE with `enter_to_send: true`
