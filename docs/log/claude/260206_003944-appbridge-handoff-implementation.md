# AppBridge Handoff Implementation

## Instructions
Codex built the AppBridge (macOS menubar app / LINE automation bridge). Implement continuation tasks from the handoff document.

## Work Done

### Task 0: Compile Error Fixes
- `BridgeTokenManager.swift:12` - Removed redundant `, let token` in double Optional binding (Swift 5.9 flattens `try?`)
- `LINEAdapter.swift:29-42` - Fixed `launchApplication` return type from Optional binding to Bool check, added `Thread.sleep(0.5)` and re-fetch of `NSRunningApplication`
- Build verified: `swift build` passed

### Task 5: Error Code Test Expansion
- `Tests/UnitTests/BridgeCoreTests.swift` - Added 10 new test cases:
  - `testSendReturnsAdapterNotFound` - unregistered adapter
  - `testSendReturnsUnsupportedAction` - unsupported action
  - `testSendReturnsInvalidConversationHint` - blank hint
  - `testSendReturnsInvalidText` - blank text
  - `testSendReturnsInvalidJson` - malformed JSON
  - `testSendReturnsRetriableError` - FailingAdapter -> 503
  - `testTokenRegenerationInvalidatesOldToken`
  - `testTokenValidateRejectsNil`
  - `testUnauthorizedRequestIsRejected`
  - `testMissingTokenIsRejected`
- `Tests/UnitTests/EventBusTests.swift` - Added 3 new test cases:
  - `testEventBusDropsOldEventsWhenOverflow` - 1001 events -> 1000 kept
  - `testSubscribeReceivesEvents` - callback fires on append
  - `testUnsubscribeStopsEvents` - callback stops after unsubscribe
- Total: 17 tests, 0 failures

### Task 4: SSE Last-Event-ID Support
- `BridgeRequestHandler.swift` - Modified `startSSE` to accept `lastEventID` parameter
  - Parse `Last-Event-ID` header from request
  - With Last-Event-ID: replay all events since that ID
  - Without: send latest 3 events (existing behavior)
- `writeSSE` now emits `id: {event.id}` field in SSE format

### Task 2: AX Tree Rescan After Navigation
- `LINEAdapter.swift` - Changed `let nodes` to `var nodes`
- Added `rescan_after_navigation` step after `open_conversation`
  - Polls up to 4 times (0.5s interval) for messageInput element
  - Uses fresh AXQuery.descendants scan each attempt
  - Throws `rescan_timeout` if messageInput not found within 2s
- `input_message` and `send_message` steps now use rescanned nodes

### Task 3: Inbound Message Diff Detection
- `AppBridge/Adapters/LINE/LINEInboundWatcher.swift` - NEW file
  - Timer-based polling of LINE's AX tree
  - Detects last AXStaticText change in focused window
  - Ring buffer of 20 hashes for deduplication
  - Fires `inbound_message` event to EventBus on new message
- `AppBridge/main.swift` - Replaced heartbeat Timer with `LINEInboundWatcher`

### Task 1: LineSelectors Tuning (Pending)
- Requires LINE app running with Accessibility permission
- Deferred - needs interactive axdump session

## Changed Files
| File | Line(s) | Change |
|------|---------|--------|
| `AppBridge/Core/Security/BridgeTokenManager.swift` | 12 | Remove redundant Optional bind |
| `AppBridge/Adapters/LINE/LINEAdapter.swift` | 29-58, 80-111 | Fix launchApp, add rescan step |
| `AppBridge/Core/BridgeServer/BridgeRequestHandler.swift` | 81-83, 93-123 | SSE id: field + Last-Event-ID |
| `AppBridge/Adapters/LINE/LINEInboundWatcher.swift` | NEW | Inbound message watcher |
| `AppBridge/main.swift` | 14-28 | Replace heartbeat with watcher |
| `Tests/UnitTests/BridgeCoreTests.swift` | 15-185 | 10 new test cases |
| `Tests/UnitTests/EventBusTests.swift` | 15-59 | 3 new test cases |

## Issues
- Task 1 (LineSelectors tuning) requires interactive session with LINE running
- Deprecation warnings in LINEAdapter for `launchApplication(withBundleIdentifier:)` - existing issue, not in scope
