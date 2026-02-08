# Re-pair Backoff & Circuit Breaker

**Date**: 2026-02-08 11:52
**Task**: Fix OpenClaw plugin polling stop bug caused by re-pair spam

## Problem

- Gateway restart -> auto-pair success -> polling starts
- 21:26:15~21:33:29: 6 re-pair cycles in quick succession
- 21:33:29 onward: clawgate plugin logs completely silent (polling permanently stopped)

### Root Cause

1. `pair/request` calls `tokenManager.regenerateToken()` which invalidates the old token
2. External `curl` calls to `pair/generate` + `pair/request` can invalidate the plugin's token
3. When plugin detects `unauthorized`, it re-pairs immediately (no delay)
4. Re-pair itself triggers `pair/generate` + `pair/request`, creating a self-invalidation cycle
5. No backoff or retry limit -> high-speed loop until something breaks

**Note**: `pair/generate` alone does NOT invalidate tokens (only generates a pairing code).
Token invalidation happens in `pair/request` via `tokenManager.regenerateToken()`.

## Fix

Added to `extensions/openclaw-plugin/src/gateway.js`:

### 1. Exponential Backoff
- Initial: 3s, doubles on each failure, capped at 60s
- Resets to initial on successful re-pair

### 2. Circuit Breaker
- Tracks re-pair attempts in a 5-minute sliding window
- If 5+ attempts in window: 60s cooldown before next attempt
- Prevents runaway re-pair loops

### 3. Logging
- Each re-pair attempt logs backoff duration and attempt count
- Circuit breaker trips are logged with attempt count
- Failure logs include next backoff duration

## Changed Files

- `extensions/openclaw-plugin/src/gateway.js:126-166` — backoff/circuit breaker state and functions
- `extensions/openclaw-plugin/src/gateway.js:430-454` — re-pair logic in polling loop

## Deployment

```bash
cp -R extensions/openclaw-plugin/ ~/.openclaw/extensions/clawgate/
pkill -f "openclaw.*gateway"  # KeepAlive restarts automatically
```

## Verification

- Gateway restarted with new code: auto-pair OK, doctor OK, polling active
- No re-pair spam observed in logs after deployment
- Deployed code matches source (diff confirmed)
