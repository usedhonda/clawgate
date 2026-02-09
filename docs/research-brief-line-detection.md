# LINE Message Detection Improvement — Codex Research Brief

## Objective

Research how to improve LINE Desktop (macOS Qt) message detection beyond notification banner monitoring.

**Core problem**: The current primary detection (notification banner monitoring) fails when LINE notifications are not displayed on screen (DND, Focus mode, notifications disabled, banner timing issues). We need a hybrid approach combining multiple signals that don't depend on notification banners.

---

## 1. Project Overview

**ClawGate** — macOS menubar app. Automates LINE Desktop via Accessibility API, bridging AI agent (OpenClaw) and LINE.

**Hard constraints (must not violate):**
- No unofficial network analysis, packet modification, or token DB parsing of LINE
- No traffic interception or encryption breaking
- Limited to "automating UI operations on the user's own Mac with user permission"
- macOS official APIs only (AX, Vision, CGEvent, NSDistributedNotification, etc.)

---

## 2. Current Detection Architecture (3 layers)

### 2a. Notification Banner Watcher (primary, event-driven)

| Item | Details |
|------|---------|
| Mechanism | AXObserver on `com.apple.notificationcenterui` for `kAXWindowCreatedNotification` |
| Fallback | 2-second polling scanning notification banner AX tree |
| Extracted data | Sender name + message body (from AXStaticText, no OCR needed) |
| Accuracy | High (system font, AX text extraction is reliable) |
| Latency | Near real-time (AXObserver event-driven + 300ms render wait) |

**Weaknesses:**
- Completely blind when DND / Focus mode suppresses banners
- Must scan within the short window between banner appearance and dismissal
- Banners appear even when LINE is in background, but powerless if user disabled notifications

### 2b. AX Row Count Detection (structural change)

| Item | Details |
|------|---------|
| Mechanism | 2-second polling of AXList (chat area) AXRow count in LINE window |
| Detection | Row count increase or bottom row Y-coordinate change |
| Text extraction | Vision OCR on new row's frame region |
| Accuracy | Medium (OCR quality dependent) |
| Latency | Up to 2 seconds (polling interval) |

**Weaknesses:**
- AXRow's `AXValue` returns error(-25212) — OCR required
- Qt doesn't fire `kAXRowCountChangedNotification` — polling required
- LINE in background = AXWindow=0, detection impossible
- Virtual scroll coordinates (y=-17000 etc.) differ from screen coordinates

### 2c. Pixel Diff Detection (visual change)

| Item | Details |
|------|---------|
| Mechanism | CGWindowListCreateImage of chat area bottom half → 32x32 downsample → FNV-1a hash |
| Detection | Hash change → Vision OCR → OCR text change |
| Accuracy | Medium-high (hash is sensitive but OCR accuracy varies) |
| Latency | 2s polling + 300ms OCR |
| Permission | Screen Recording permission additionally required |

**Weaknesses:**
- OCR captures entire chat area, hard to extract only new messages
- Triggers on scroll, typing indicators, and other noise
- Requires Screen Recording permission (AX permission alone insufficient)

---

## 3. Cross-cutting Issues

### 3a. Text Extraction Reliability

| Method | Status | Problem |
|--------|--------|---------|
| AX Value (AXStaticText) | error(-25212) on LINE Qt | Qt's AX implementation doesn't expose value |
| Vision OCR | Works but slow (300ms) | Japanese accuracy varies, old messages mix in |
| Clipboard | Not implemented | Select → Copy → Read flow is destructive (overwrites user clipboard) |

### 3b. Echo Suppression

- Blanket suppression of events within 8 seconds after send (no per-conversation identification: LINE Qt window title is always "LINE")
- No text matching (unreliable due to OCR noise)
- Plugin has 45-second second layer

### 3c. Background Constraints

- LINE in background = empty AX tree (AXWindow=0)
- Only Notification Banner works in background
- `kAEReopenApplication` can restore window but disrupts user

---

## 4. Research Questions for Codex

**Context**: Notification banners are often not shown, so banner monitoring alone is insufficient. We need notification-independent signals.

### Q1: Can network activity be used as a trigger? (HIGHEST PRIORITY)

No need to read packet contents. Just detecting "LINE process received data from server" timing would be a strong signal for message arrival.

- **Network Extension (NEFilterDataProvider)**: Detect LINE's incoming data flow, get only "data arrived" events. Ignore payload content. This is official macOS API. App Sandbox compatibility? Requires distribution as System Extension?
- **`nettop -p <LINE_PID>` pipe monitoring**: Poll LINE process's received byte count, trigger on increase. Works without root?
- **`lsof` / `netstat` polling**: Detect changes in LINE's socket connection state
- **`proc_pidinfo` / `libproc`**: Programmatically get process network stats (bytes_in)
- **Does this constitute "traffic interception"?**: When only metadata (byte count increase timing) is used and payload is never touched

### Q2: Can process activity changes be detected?

- **`proc_pidinfo` + `PROC_PIDTASKALLINFO`**: Detect momentary CPU/memory/IO changes in LINE process (possible IO spike on message receipt)
- **`fs_usage -w -f network <LINE_PID>`**: Monitor LINE's network syscalls (root required?)
- **Endpoint Security Framework**: Monitor LINE's file access and network activity. Official macOS API but strict signing requirements?
- **`DTrace`**: Limited by SIP, but usable for own process or specific probes?

### Q3: Can LINE's local data changes be used as a trigger?

- Does LINE Desktop store data under `~/Library/Application Support/` or `~/Library/Containers/` (SQLite DB, cache, logs)?
- **FSEvents / DispatchSource.makeFileSystemObjectSource** to monitor file changes → local data may update on new message arrival
- Does this constitute "token DB parsing"? (When file contents are not read, only "change occurred" fact is used)

### Q4: Can macOS notification system be leveraged without banner display?

- **Notification database** (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`): Is it written to even during DND? Can FSEvents monitor it?
- **`NSDistributedNotificationCenter`**: Does LINE internally post notifications? (inter-app notifications)
- **`UNUserNotificationCenter` notification list API**: Can `getDeliveredNotifications()` periodically read notifications queued during DND?
- **Notification queue itself rather than notification center AXWindow**: Do notifications exist in queue even when banners are hidden?

### Q5: What's the optimal hybrid design?

Adding to the current 3 layers (Banner + AX Row + PixelDiff):
- **Network activity** (Q1) as "layer 0 trigger": Received bytes increase → immediately trigger AX/OCR scan (no polling wait)
- **Notification DB change** (Q4) as "layer 0.5 trigger"
- **Confidence scoring**: Methods to combine multi-layer signals for higher accuracy
- **Battery/CPU impact**: Balance between polling intervals and event-driven approaches

### Q6: How do other messenger automation tools detect messages?

- **Hammerspoon**: hs.application.watcher + hs.uielement.watcher use cases
- **Keyboard Maestro**: New message detection patterns for chat apps
- **LINE Bot (Messaging API)**: Can official Bot account be an alternative? (If user adds Bot as friend, receive via Webhook. Requires LINE Official Account though)
- **Electron/Chromium-based apps** can use DevTools Protocol, but what about Qt apps?

---

## 5. Expected Output

1. **Feasibility/risk/policy compliance assessment table for each approach**
2. **Recommended hybrid configuration** (how to improve on current 3-layer base)
3. **macOS version dependencies** (compatible with Sonoma/Sequoia?)
4. **Required permissions list** (AX, Screen Recording, Full Disk Access, Network Extension, etc.)
5. **Priority matrix of implementation difficulty vs. impact**

---

## 6. Current Code Structure (reference)

| File | Role |
|------|------|
| `ClawGate/Adapters/LINE/LINEInboundWatcher.swift` | AX Row Count + Pixel Diff (2s polling) |
| `ClawGate/Adapters/LINE/NotificationBannerWatcher.swift` | Notification banner monitoring (AXObserver + 2s fallback) |
| `ClawGate/Core/EventBus/RecentSendTracker.swift` | Echo suppression (8s temporal window) |
| `ClawGate/Automation/Vision/VisionOCR.swift` | Vision OCR wrapper |
| `ClawGate/Automation/AX/AXQuery.swift` | AX tree traversal |
| `ClawGate/Automation/AX/AXActions.swift` | AX action execution |
| `ClawGate/Automation/Selectors/LineSelectors.swift` | LINE UI element geometry hints |
