# AppBridge -> ClawGate Rename & LineSelectors Tuning

## Instructions
- Phase A: Rename AppBridge -> ClawGate (external-facing only)
- Phase B: Tune LineSelectors with real AX dump data

## Phase A: Rename Changes

### Directory
- `AppBridge/` -> `ClawGate/`
- `Sources/AppBridge/` deleted (SPM stub)
- Empty `Sources/` directory removed

### Package.swift
- Package name, executable name, target name, path: `AppBridge` -> `ClawGate`
- Test dependency: `["AppBridge"]` -> `["ClawGate"]`

### Source files changed
| File | Change |
|------|--------|
| `ClawGate/UI/MenuBarApp.swift:17,38` | UI title "AppBridge" -> "ClawGate" |
| `ClawGate/UI/SettingsView.swift:19` | "AppBridge Settings" -> "ClawGate Settings" |
| `ClawGate/Core/Security/KeychainStore.swift:12` | `com.appbridge.local` -> `com.clawgate.local` |
| `ClawGate/Core/Config/AppConfig.swift:17-19` | `appbridge.*` -> `clawgate.*` UserDefaults keys |
| `ClawGate/main.swift:23,25,34` | Log strings "BridgeServer" -> "ClawGate" |
| `Tests/UnitTests/BridgeCoreTests.swift:4` | `@testable import ClawGate` |
| `Tests/UnitTests/BridgeCoreTests.swift` | `com.appbridge.test.*` -> `com.clawgate.test.*` (5 places) |
| `Tests/UnitTests/BridgeCoreTests.swift` | `appbridge.tests.*` -> `clawgate.tests.*` (4 places) |
| `Tests/UnitTests/EventBusTests.swift:2` | `@testable import ClawGate` |

### NOT changed (intentional)
- Class names: BridgeCore, BridgeServer, BridgeTokenManager etc.
- X-Bridge-Token header
- Keychain account: bridge.token
- docs/, AGENTS.md (historical records)

## Phase B: AX Dump Findings

### AXDump.swift improvements
- Added `subrole`, `identifier` fields to AXDumpNode
- Added `firstWindow()` fallback (kAXWindowsAttribute) when focusedWindow is nil
- Increased defaults: maxDepth 4->8, maxChildren 8->30

### AXQuery.swift improvements
- Added `subrole` field to AXNode struct
- Added subrole filtering in `bestMatch()`
- traverse() now reads kAXSubroleAttribute

### LINE Mac AX tree observations
- LINE is Qt-based (identifiers show `qt_itemFired:`)
- **focusedWindow works ONLY when LINE is the foreground app**
- kAXWindowsAttribute also returns nil when LINE is backgrounded
- AXTextArea: message input (title/description are EMPTY)
- AXTextField: search field (not visible in focused chat view)
- No send button in AX tree - LINE uses Enter key to send
- Window title = current conversation name (e.g. "usedbot")

### LineSelectors.swift updates
- messageInput: removed titleContains/descriptionContains (always empty in LINE)
- Added subrole field to LineSelector struct
- Added comments documenting LINE's AX behavior
- sendButton kept as fallback but documented that Enter key is the primary method

## Verification
- `swift build`: pass (warnings only: deprecated launchApplication)
- `swift test`: 17/17 pass
- `swift run ClawGate`: server starts, menu bar shows "ClawGate"
- `GET /v1/health`: `{"ok":true,"version":"0.1.0"}`
- `GET /v1/axdump`: returns LINE window tree when LINE is focused

## Issues / Future Work
- Search field (AXTextField) not visible in focused chat view - need sidebar view dump
- LINE's AX tree has empty title/description on most elements
- Need to explore position-based or hierarchy-based matching as alternative to title matching
