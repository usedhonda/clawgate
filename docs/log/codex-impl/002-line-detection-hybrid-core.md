# 002 - LINE detection hybrid core refactor

Date: 2026-02-09

## Summary
Implemented the core detection-logic rework by introducing signal fusion for LINE inbound detection, while preserving legacy mode and existing event API compatibility.

## Scope
- Added LINE detection core types and fusion engine.
- Refactored `LINEInboundWatcher` to collect structured signals and emit confidence/scoring metadata.
- Added LINE detection settings to config model and `/v1/config` response.
- Wired new settings through runtime initialization.
- Extended notification-banner payload with confidence/signal metadata.

## Changed files
- `ClawGate/Adapters/LINE/Detection/LineDetectionTypes.swift` (new)
- `ClawGate/Adapters/LINE/Detection/LineDetectionFusionEngine.swift` (new)
- `ClawGate/Adapters/LINE/LINEInboundWatcher.swift`
- `ClawGate/Adapters/LINE/NotificationBannerWatcher.swift`
- `ClawGate/Core/Config/AppConfig.swift`
- `ClawGate/Core/BridgeServer/BridgeModels.swift`
- `ClawGate/Core/BridgeServer/BridgeCore.swift`
- `ClawGate/main.swift`

## Behavior changes
1. `LINEInboundWatcher` now emits scored events with fields:
   - `confidence`, `score`, `signals`, `pipeline_version`
2. Detection mode support:
   - `legacy`: emit based on first signal
   - `hybrid` (default): fuse multiple signals and emit only above threshold
3. Config additions:
   - `lineDetectionMode`
   - `lineFusionThreshold`
   - `lineEnablePixelSignal`
   - `lineEnableProcessSignal`
   - `lineEnableNotificationStoreSignal`
4. Added watcher state helpers:
   - `snapshotState()`
   - `resetBaseline()`

## Notes
- `enableProcessSignal` and `enableNotificationStoreSignal` are wired but intentionally not fully implemented yet (phase hooks).
- Existing payload keys (`text`, `conversation`, `source`) remain present for compatibility.

## Validation
Attempted `swift build`, but local environment blocked verification due toolchain/sandbox issues:
- Swift SDK/compiler mismatch error
- Module cache write permission error under `~/.cache/clang/ModuleCache`
