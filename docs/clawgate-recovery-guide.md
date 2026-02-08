# ClawGate Recovery Guide

This file is intended for AI agents working in **other OpenClaw projects** (e.g. vibeterm).
When LINE stops working via OpenClaw, read this file to diagnose and recover.

---

## What is ClawGate?

A macOS menubar app that bridges OpenClaw to LINE via Accessibility API.
It runs an HTTP server on `127.0.0.1:8765` and is registered as an OpenClaw channel plugin.

**No authentication is required.** ClawGate binds to localhost only — no external access is possible.
CSRF protection is provided by Origin header check on POST requests.

**Without ClawGate running and healthy, OpenClaw cannot send or read LINE messages.**

---

## Quick Health Check

```bash
# 1. Is ClawGate running?
pgrep -f ClawGate.app

# 2. Is the HTTP server responding?
curl -s http://localhost:8765/v1/health

# 3. Full diagnosis (no auth needed)
curl -s http://localhost:8765/v1/doctor | python3 -m json.tool
```

Doctor checks: `accessibility_permission`, `line_running`, `line_window_accessible`, `server_port`, `screen_recording_permission`.

---

## Common Failure Modes & Recovery

### 1. ClawGate is not running

**Symptom:** `curl localhost:8765/v1/health` -> connection refused.

**Fix:**

```bash
open /Users/usedhonda/projects/Mac/clawgate/ClawGate.app
```

### 2. LINE is not running or has no window

**Symptom:** Doctor reports `line_running: error` or `line_window_accessible: error`.

**Fix:**

```bash
# Launch LINE
open -a LINE

# If LINE is running but has no window (backgrounded):
# ClawGate sends kAEReopenApplication automatically on /v1/send calls.
# If that doesn't work, activate LINE manually:
osascript -e 'tell application "LINE" to activate'
```

### 3. Accessibility permission lost

**Symptom:** Doctor reports `accessibility_permission: error`.

**Cause:** ClawGate binary was re-signed with ad-hoc (`--sign -`), changing its CDHash.

**Fix:** User must manually toggle in System Settings:
1. System Settings > Privacy & Security > Accessibility
2. Find ClawGate -> toggle OFF then ON

**Prevention:** Always sign with `--sign "ClawGate Dev"` (stable CDHash).

### 4. OpenClaw gateway itself is down

**Symptom:** `curl localhost:18789` -> connection refused.

**Fix:**

```bash
launchctl start ai.openclaw.gateway
```

### 5. OpenClaw gateway lost connection to ClawGate

**Symptom:** OpenClaw logs show connection errors or doctor check failures.

**Fix:** Restart the OpenClaw gateway — it will reconnect on startup.

```bash
launchctl stop ai.openclaw.gateway && sleep 2 && launchctl start ai.openclaw.gateway
```

Then watch gateway logs for `doctor OK`:

```bash
tail -f ~/.openclaw/logs/gateway.log
```

---

## Key Paths

| Path | What |
|------|------|
| `/Users/usedhonda/projects/Mac/clawgate/` | ClawGate source |
| `/Users/usedhonda/projects/Mac/clawgate/ClawGate.app` | Built app bundle |
| `/Users/usedhonda/projects/Mac/clawgate/scripts/dev-deploy.sh` | Build + deploy + smoke-test |
| `~/.openclaw/extensions/vibeterm-telemetry/` | Telemetry plugin (deployed copy) |
| `~/.openclaw/openclaw.json` | OpenClaw config (gateway token, plugin entries) |
| `~/.openclaw/logs/gateway.log` | OpenClaw gateway logs |

---

## Do NOT Do These

| Action | Why |
|--------|-----|
| `tccutil reset Accessibility com.clawgate.app` | Deletes AX permission entry entirely |
| `codesign --sign -` (ad-hoc) | Changes CDHash, breaks AX permission |
| `dev-deploy.sh --skip-plugin` | Skips OpenClaw plugin sync, gateway gets out of sync |

---

## Full Recovery Sequence (nuclear option)

If everything is broken and you don't know what happened:

```bash
# 1. Rebuild and redeploy ClawGate (includes OpenClaw plugin sync + smoke-test)
cd /Users/usedhonda/projects/Mac/clawgate
./scripts/dev-deploy.sh

# 2. Restart OpenClaw gateway (reconnects automatically)
launchctl stop ai.openclaw.gateway && sleep 2 && launchctl start ai.openclaw.gateway

# 3. Wait and verify
sleep 5
tail -20 ~/.openclaw/logs/gateway.log | grep -E "doctor|cursor"
```

Expected log output:
```
doctor OK
initial cursor
```

After these lines appear, LINE messaging via OpenClaw is operational.
