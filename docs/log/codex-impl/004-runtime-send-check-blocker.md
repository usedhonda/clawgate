# 004 - Runtime send check and blocker

Date: 2026-02-10

## What was executed
1. `POST /v1/send` with LINE payload
2. `GET /v1/poll`
3. `GET /v1/doctor`

## Results
### `/v1/send`
- Response:
  - `ok: false`
  - `code: ax_permission_missing`
  - `message: Accessibility permission is not granted`

### `/v1/poll`
- Response: no events (`events: []`)

### `/v1/doctor`
- `accessibility_permission`: `error`
- `line_running`: `ok`
- `line_window_accessible`: `warning` (skipped due AX permission)
- `server_port`: `ok`
- `screen_recording_permission`: `warning`

## Diagnosis
- Core code changes are built and server is running.
- Runtime send validation is currently blocked by macOS TCC permission state after app replacement/re-signing.

## Recovery steps (manual, required)
1. Open System Settings > Privacy & Security > Accessibility.
2. Ensure `ClawGate.app` is enabled.
3. If it exists but still fails, remove and re-add `ClawGate.app`, then relaunch app.
4. (Optional for pixel signal) Enable Screen Recording for `ClawGate.app`.

## Re-check commands
```bash
curl -sS http://127.0.0.1:8765/v1/doctor
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"adapter":"line","action":"send_message","payload":{"conversation_hint":"Yuzuru Honda","text":"[ClawGate test] hybrid check","enter_to_send":true}}' \
  http://127.0.0.1:8765/v1/send
curl -sS 'http://127.0.0.1:8765/v1/poll'
```
