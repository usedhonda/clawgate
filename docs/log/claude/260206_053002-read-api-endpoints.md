# Read API Endpoints Implementation

## Instructions
Add 3 read-only endpoints: GET /v1/context, GET /v1/messages, GET /v1/conversations

## Changes

### Phase 1: Shared Infrastructure
- `ClawGate/Core/BridgeServer/BridgeModels.swift`: Added 5 models (ConversationContext, VisibleMessage, MessageList, ConversationEntry, ConversationList)
- `ClawGate/Adapters/AdapterProtocol.swift`: Added getContext(), getMessages(), getConversations() with default throws
- `ClawGate/Adapters/LINE/LineSelectors.swift`: Added messageTextU, conversationNameU selectors
- `ClawGate/Adapters/LINE/LINEAdapter.swift`: Added withLINEWindow<T> helper

### Phase 2: GET /v1/context
- `LINEAdapter.getContext()`: Window title + input field check
- `BridgeCore.context()`: Adapter dispatch + error handling
- `BridgeRequestHandler`: /v1/context route

### Phase 3: GET /v1/messages
- `LINEAdapter.getMessages()`: AXStaticText geometry filter, UI chrome filter, Y-sort, X-based sender detection
- `LINEAdapter.isUIChrome()`: Timestamp/digit/single-char/window-title filter (static method for testability)
- `BridgeCore.messages()`: Adapter dispatch

### Phase 4: GET /v1/conversations
- `LINEAdapter.getConversations()`: Sidebar filter, Y-proximity grouping, unread detection
- `BridgeCore.conversations()`: Adapter dispatch

### Phase 5: LINEInboundWatcher
- `LINEInboundWatcher.swift:60`: Added "conversation" field to inbound_message payload

### Phase 6: Tests
- `Tests/UnitTests/BridgeCoreTests.swift`: FakeAdapter stubs + 4 new tests (context/messages/conversations/unsupported)
- `Tests/UnitTests/ChromeFilterTests.swift`: 9 new tests for isUIChrome

## Results
- `swift build`: Success (only pre-existing deprecation warnings)
- `swift test`: 43 tests, 0 failures (was 30, added 13)

## Files Modified
- ClawGate/Core/BridgeServer/BridgeModels.swift
- ClawGate/Adapters/AdapterProtocol.swift
- ClawGate/Adapters/LINE/LineSelectors.swift
- ClawGate/Adapters/LINE/LINEAdapter.swift
- ClawGate/Core/BridgeServer/BridgeCore.swift
- ClawGate/Core/BridgeServer/BridgeRequestHandler.swift
- ClawGate/Adapters/LINE/LINEInboundWatcher.swift
- Tests/UnitTests/BridgeCoreTests.swift
- Tests/UnitTests/ChromeFilterTests.swift (new)
