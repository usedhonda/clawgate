# UniversalSelector System Implementation

## Instruction
Implement 4-layer selector pipeline with capability scoring for AX element matching.

## Work Done

### Phase 1: AXQuery Extension
- **AXQuery.swift**: Added `identifier`, `roleDescription`, `frame`, `actions`, `settableAttributes`, `value` to `AXNode`
- Added helper functions: `copyFrameAttribute`, `copyActionNames`, `copySettableAttributes`, `elementAtPosition` (hit-test)
- **AXDump.swift**: Added `CodableRect` struct, updated `AXDumpNode` with `roleDescription`, `frame`, `actions`, `settableAttributes`, `value`

### Phase 2: UniversalSelector System (new files)
- **GeometryHint.swift**: `Direction`, `GeometryHint`, `NeighborHint` types
- **UniversalSelector.swift**: `UniversalSelector`, `SelectorCandidate` types
- **SelectorResolver.swift**: L1 (identifier/text hint match) + L3 (capability + geometry) resolution with confidence scoring

### Phase 3: LineSelectors Migration
- **LineSelectors.swift**: Added `messageInputU`, `searchFieldU`, `sendButtonU` (UniversalSelector-based). Legacy selectors kept for backward compatibility.
- **LINEAdapter.swift**: Uses `SelectorResolver.resolve()` with fallback to legacy `legacyResolve()`. Added `get_window_frame` step for geometry-based matching.

### Phase 4: Micro-foreground
- **AXActions.swift**: Added `setFocused()`, `withFocus(on:bundleIdentifier:action:)` - tries AXFocused first, falls back to micro-foreground pattern (activate -> action -> restore).

### Tests
- **SelectorResolverTests.swift**: 13 new tests covering L1 identifier, L1 text hint, L3 capability, L3 geometry, L3 scoring, LINE-specific selectors, no-match

## Changed Files
| File | Lines | Operation |
|------|-------|-----------|
| ClawGate/Automation/AX/AXQuery.swift | 4-16, 77-91, 99-161 | Modified |
| ClawGate/Automation/AX/AXDump.swift | 5-22, 49-51, 64-80 | Modified |
| ClawGate/Automation/AX/AXActions.swift | 1-62 | Modified |
| ClawGate/Automation/Selectors/GeometryHint.swift | - | **New** |
| ClawGate/Automation/Selectors/UniversalSelector.swift | - | **New** |
| ClawGate/Automation/Selectors/SelectorResolver.swift | - | **New** |
| ClawGate/Adapters/LINE/LineSelectors.swift | full | Modified |
| ClawGate/Adapters/LINE/LINEAdapter.swift | 80-210 | Modified |
| Tests/UnitTests/SelectorResolverTests.swift | - | **New** |

## Verification
- `swift build`: OK (only pre-existing deprecation warnings)
- `swift test`: 30 tests, 0 failures (was 17, added 13)

## Issues
- L2 (Path Match) and L4 (Visual/OCR Fallback) are not yet implemented (future phases)
- Legacy `LineSelector` type and `AXQuery.bestMatch()` kept for backward compatibility
