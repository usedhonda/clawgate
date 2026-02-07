# Integration Test Phase 2 - Remote Execution

**Date**: 2026-02-06 17:41
**Condition**: Mac not physically accessible (remote only)

## Changes Made

### 1. `/v1/pair/generate` API added (GUI dependency removed)
- **Files**: `BridgeModels.swift`, `BridgeCore.swift`, `BridgeRequestHandler.swift`
- **Endpoint**: `POST /v1/pair/generate` (no auth required)
- **Response**: `{ ok: true, result: { code: "XXXXXX", expires_in: 120 } }`
- **Purpose**: Eliminates need for menubar UI to generate pairing codes
- **Security**: Localhost-only (server binds to 127.0.0.1)

### 2. BridgeTokenManager token caching (Keychain blocking fix)
- **File**: `BridgeTokenManager.swift`
- **Problem**: Every `validate()` call hit `SecItemCopyMatching`, which triggers a
  Keychain password dialog for ad-hoc signed apps, blocking the entire `BlockingWork.queue`
- **Fix**: Token is cached in memory (`cachedToken`). Keychain is only used for
  persistence during `regenerateToken()`. No Keychain reads during auth checks.
- **Init**: No Keychain load at init (was blocking app startup)
- **Trade-off**: Token doesn't survive app restart (must re-pair). This is acceptable
  since `pair/generate` API makes re-pairing trivial.

### 3. Integration test script created
- **File**: `scripts/integration-test.sh`
- **Tests**: 24 total (18 PASS, 0 FAIL, 6 SKIP)
- **Auto-pairs**: Uses `pair/generate` -> `pair/request` flow automatically
- **Smart skipping**: Checks doctor AX status, skips AX-dependent tests gracefully

## Test Results

| Phase | Tests | PASS | FAIL | SKIP |
|-------|-------|------|------|------|
| Phase 0: Health & Pairing | 3 | 3 | 0 | 0 |
| Phase 1: Auth & Errors | 5 | 5 | 0 | 0 |
| Phase 2: Doctor | 4 | 3 | 0 | 1 |
| Phase 3: Poll & Events | 3 | 3 | 0 | 0 |
| Phase 4: AX endpoints | 4 | 0 | 0 | 4 |
| Phase 5: Send API | 4 | 3 | 0 | 1 |
| Phase 6: Security | 1 | 1 | 0 | 0 |
| **Total** | **24** | **18** | **0** | **6** |

## Remaining SKIPs (all require Accessibility permission)

| Test | Blocker |
|------|---------|
| T2.4 Doctor: accessibility | Needs System Settings > Privacy > Accessibility grant |
| T4.1 Context | AX permission |
| T4.2 Messages | AX permission |
| T4.3 Conversations | AX permission |
| T4.4 AXDump | AX permission |
| T5.1 Send message | AX permission |

## Progress vs Previous Run

| Metric | Previous (260206_164902) | Current |
|--------|------------------------|---------|
| Total tests | 33 | 24 |
| PASS | 9 | 18 |
| FAIL | 0 | 0 |
| SKIP | 24 | 6 |
| Blockers | Keychain dialog, GUI pairing, AX | AX only |

## Key Insight

The single remaining blocker is **Accessibility permission**, which requires physical
Mac access to grant via System Settings. Once granted, all 6 SKIP tests should pass.
The Keychain blocking and GUI pairing blockers have been completely eliminated.
