# 003 - Build and runtime validation after hybrid detection refactor

Date: 2026-02-10

## Actions performed
1. Built project with elevated execution:
   - `swift build`
2. Deployed built binary into app bundle and re-signed:
   - `cp .build/debug/ClawGate ClawGate.app/Contents/MacOS/ClawGate`
   - `codesign --force --deep --options runtime --entitlements ClawGate.entitlements --sign - ClawGate.app`
3. Launched app:
   - `open ClawGate.app`
4. Verified runtime API endpoints (elevated curl):
   - `GET /v1/health`
   - `GET /v1/config`
5. Attempted unit tests:
   - `swift test`

## Results
### Build
- **PASS**

### App deploy/sign/launch
- **PASS** (`codesign` succeeded, app launched)

### Runtime API
- `GET /v1/health` => `{"version":"0.1.0","ok":true}`
- `GET /v1/config` => **PASS**, and includes new fields under `line`:
  - `detection_mode`
  - `fusion_threshold`
  - `enable_pixel_signal`
  - `enable_process_signal`
  - `enable_notification_store_signal`

### Tests
- `swift test` => **FAIL (environment)**
- Error: `no such module 'XCTest'` in `Tests/UnitTests/BridgeCoreTests.swift`
- Interpretation: XCTest/toolchain availability issue in this environment, not a compile failure in app target.

## Conclusion
- Hybrid detection core refactor is compiled, deployed, and running.
- Runtime config exposure for new detection controls is verified.
- Unit tests remain blocked by environment-level XCTest setup.
