# ClawGate Testing Parameters

These parameters are **permanent**. Never ask the user to confirm them again.
After context refresh, read this file to restore test parameters.

## send_message Test

| Parameter | Value | Notes |
|-----------|-------|-------|
| adapter | `line` | LINE adapter |
| action | `send_message` | |
| conversation_hint | `<CONTACT_NAME>` | Exists in LINE sidebar |
| text | `ClawGate test` | Test message body |
| enter_to_send | `true` | Enter key sends message |

### curl command (copy-paste ready)

```bash
curl -s -X POST -H "X-Bridge-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"adapter":"line","action":"send_message","payload":{"conversation_hint":"<CONTACT_NAME>","text":"ClawGate test","enter_to_send":true}}' \
  localhost:8765/v1/send | python3 -m json.tool
```

## E2E Test

Same parameters as above, but with screenshot before/after and messages API verification.

```bash
# Before
screencapture -x /tmp/clawgate-e2e-before.png

# Send
curl -s -X POST -H "X-Bridge-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"adapter":"line","action":"send_message","payload":{"conversation_hint":"<CONTACT_NAME>","text":"E2E test","enter_to_send":true}}' \
  localhost:8765/v1/send | python3 -m json.tool

# After
sleep 2
screencapture -x /tmp/clawgate-e2e-after.png

# Verify
curl -s -H "X-Bridge-Token: $TOKEN" localhost:8765/v1/messages | python3 -m json.tool
```
