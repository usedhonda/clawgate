# 005 - Accessibility permission recovery attempt

Date: 2026-02-10

## Performed
1. Verified server process path listening on 8765:
   - `/Users/usedhonda/projects/Mac/clawgate/ClawGate.app/Contents/MacOS/ClawGate`
2. Verified bundle identity/signature:
   - Identifier: `com.clawgate.app`
   - Signature: ad-hoc
3. Relaunched app and rechecked doctor.
4. Reset TCC entry:
   - `tccutil reset Accessibility com.clawgate.app`
5. Relaunched app and rechecked doctor.

## Current status
- `GET /v1/doctor` still reports:
  - `accessibility_permission = error`

## Conclusion
- Runtime send/e2e verification remains blocked by macOS Accessibility grant not yet re-applied after TCC reset.
