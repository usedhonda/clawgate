# Direct Gateway Setup (No Federation)

Connect OpenClaw Gateway directly to a remote ClawGate instance, without Federation.

## Prerequisites

- ClawGate running on a host with tmux sessions (Host B)
- OpenClaw Gateway running on another host (Host A)
- Network connectivity between hosts (Tailscale recommended)

## Setup

### 1. ClawGate (Host B) — Enable Remote Access

In ClawGate settings (Gateway section):

- Enable **"Allow Gateway to connect"**
- Set a **token** (shared secret)

Or via API:

```bash
# On Host B
curl -s -X PUT http://127.0.0.1:8765/v1/config \
  -H "Content-Type: application/json" \
  -d '{"remoteAccessEnabled": true, "remoteAccessToken": "your-secret-token"}'
```

ClawGate will bind to `0.0.0.0:8765` when remote access is enabled.

### 2. OpenClaw Gateway (Host A) — Point to Remote ClawGate

In `~/.openclaw/openclaw.json`, set the ClawGate channel config:

```json
{
  "channels": {
    "clawgate": {
      "default": {
        "apiUrl": "http://host-b-address:8765",
        "token": "your-secret-token"
      }
    }
  }
}
```

Or using the CLI:

```bash
openclaw config set channels.clawgate.default.apiUrl "http://host-b:8765"
openclaw config set channels.clawgate.default.token "your-secret-token"
```

Restart OpenClaw Gateway after config changes.

### 3. Verify

```bash
# From Host A, test ClawGate reachability
curl -s -H "Authorization: Bearer your-secret-token" \
  http://host-b-address:8765/v1/health

# Check doctor
curl -s -H "Authorization: Bearer your-secret-token" \
  http://host-b-address:8765/v1/doctor
```

## Security

- **Tailscale recommended**: Use Tailscale addresses (`100.x.x.x` or `hostname.tailnet`) instead of public IPs
- **Token required**: All requests must include `Authorization: Bearer <token>`
- **CSRF protection**: POST requests with `Origin` header are rejected (browser protection)
- Do not expose port 8765 to the public internet without additional access controls

## Migrating from Federation

If you previously used Federation (server/client mode):

1. On Host B: Enable remote access in ClawGate settings
2. On Host A: Change `apiUrl` in `openclaw.json` from `http://127.0.0.1:8765` to `http://host-b:8765`
3. Add `token` to `openclaw.json` matching Host B's remote access token
4. Federation can be left enabled during transition — it won't conflict with direct access
5. Once verified, Federation is no longer needed (but code remains until Phase D cleanup)

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Gateway can't reach ClawGate | `remoteAccessEnabled` is true? Firewall allows 8765? |
| 401 Unauthorized | Token matches between ClawGate and `openclaw.json`? |
| Events not arriving | Gateway polling the right `apiUrl`? Check Gateway logs |
| `/v1/send` rejected | Token correct? Check CSRF (no Origin header in server-to-server calls) |
