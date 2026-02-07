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

## InboundWatcher Test

**Verified: 2026-02-07** — Both foreground and background detection work.

### Architecture (updated 2026-02-07)

Two watchers run in parallel:

1. **NotificationBannerWatcher** (primary) — monitors `com.apple.notificationcenterui` AX tree
   for LINE notification banners. Event-driven via AXObserver + 2s fallback polling.
   Extracts sender name + message text from banner AX nodes (no OCR needed).
   Source: `"notification_banner"`

2. **LINEInboundWatcher** (fallback) — polls every 2s (was 10s).
   Two detection layers:
   - **AX row detection**: structural changes (row count/position). Source: `"poll"`
   - **Pixel diff detection**: CGImage capture -> 32x32 FNV-1a hash -> OCR on change. Source: `"pixel_diff"`

Both emit to EventBus with `source` field for disambiguation.

### How polling works

LINEInboundWatcher polls every 2 seconds with two detection layers:

1. **AX row detection**: Compares AXRow count and bottom-row Y position.
   Detects structural changes visible to the AX tree.

2. **Pixel diff detection**: Captures LINE window via CGWindowListCreateImage,
   downsamples to 32x32, computes FNV-1a hash. If hash differs from previous poll,
   runs Vision OCR on the full window. If OCR text changed, emits event.
   This catches Qt redraws invisible to AX (the primary detection method).

**Limitation**: LINE's Qt AX bridge does not expose message text in any AX attribute
(title, description, value are all empty). Pixel diff + OCR is the reliable method.

### Test procedure

```bash
# 1. Get auth token
PAIR_CODE=$(curl -s -X POST localhost:8765/v1/pair/generate | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('code',''))")
TOKEN=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"code\":\"$PAIR_CODE\"}" localhost:8765/v1/pair/request | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('token',''))")

# 2. Wait for baseline (InboundWatcher needs 1 poll cycle = 3s)
sleep 6

# 3. Get cursor
CURSOR=$(curl -s -H "X-Bridge-Token: $TOKEN" localhost:8765/v1/poll | python3 -c "import sys,json; print(json.load(sys.stdin).get('next_cursor',0))")

# 4. Send a test message
TIMESTAMP=$(date '+%H:%M:%S')
curl -s -X POST -H "X-Bridge-Token: $TOKEN" -H "Content-Type: application/json" \
  -d "{\"adapter\":\"line\",\"action\":\"send_message\",\"payload\":{\"conversation_hint\":\"Yuzuru Honda\",\"text\":\"Watcher test $TIMESTAMP\",\"enter_to_send\":true}}" \
  localhost:8765/v1/send

# 5. Wait for detection (2 poll cycles)
sleep 6

# 6. Check for inbound_message events
curl -s -H "X-Bridge-Token: $TOKEN" "localhost:8765/v1/poll?since=$CURSOR" | python3 -m json.tool
```

### Expected result

```json
{
    "ok": true,
    "events": [
        {
            "type": "inbound_message",
            "adapter": "line",
            "payload": {
                "text": "",
                "conversation": "LINE",
                "row_count_delta": "0",
                "total_rows": "11"
            }
        }
    ]
}
```

- `text: ""` — expected for poll source (LINE Qt does not expose message text via AX)
- `row_count_delta` — number of new rows (0 if rows recycled/scrolled)
- `total_rows` — current visible row count
- `source: "poll"` — from AX row detection
- `source: "pixel_diff"` — from pixel change detection (includes OCR text)
- Works with LINE in background (uses `windows().first` fallback)

### NotificationBannerWatcher expected result

```json
{
    "type": "inbound_message",
    "adapter": "line",
    "payload": {
        "text": "Hello there",
        "sender": "Yuzuru Honda",
        "source": "notification_banner"
    }
}
```

- Requires LINE notifications to be enabled in macOS System Settings
- Does NOT work when Focus/DND is active (banners suppressed)
- Works even when LINE is in background (banners are system-level)
