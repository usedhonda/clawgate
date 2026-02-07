# Echo Suppression + Vision OCR Implementation

**Date**: 2026-02-07
**Task**: InboundWatcher に Echo Suppression と Vision OCR を追加

## Changes

### New Files
- `ClawGate/Core/EventBus/RecentSendTracker.swift` — 送信タイムスタンプ追跡 (8秒窓, NSLock)
- `ClawGate/Automation/Vision/VisionOCR.swift` — CGWindowListCreateImage + VNRecognizeTextRequest

### Modified Files
- `ClawGate/Adapters/LINE/LINEAdapter.swift` — init に recentSendTracker 注入, sendMessage 成功時に recordSend
- `ClawGate/Adapters/LINE/LINEInboundWatcher.swift` — echo filter + OCR 統合
- `ClawGate/Core/BridgeServer/BridgeCore.swift` — doctor に Screen Recording チェック追加
- `ClawGate/main.swift` — DI: RecentSendTracker 共有インスタンス

## Architecture

```
LINEAdapter.sendMessage() → recentSendTracker.recordSend()
                                    ↓ (shared instance)
LINEInboundWatcher.doPoll() → recentSendTracker.isLikelyEcho()
                             → VisionOCR.extractText(from: newRowFrame)
                             → eventBus.append(type: "echo_message" | "inbound_message")
```

## Key Decisions

### Echo Suppression: Temporal Window Only
- OCR テキストマッチによる echo 判定は信頼性不足で却下
- 理由: watcher が検出する行フレームが新メッセージではなく隣接行の場合がある
- 8秒の temporal window が唯一のシグナル

### LINE Qt Window Title = "LINE" 固定
- conversation ベースのマッチは不可能（ウインドウタイトルが会話名を反映しない）
- isLikelyEcho() は adapter レベル（任意の最近の送信があれば echo）

### Vision OCR: Graceful Degradation
- Screen Recording 権限なし → VisionOCR.extractText() が nil を返す → text="" で fallback
- Doctor: screen_recording_permission は warning レベル（error ではない）

## Test Results

| Test | Result | Expected |
|------|--------|----------|
| send_message → watcher detect | `echo_message` | `echo_message` |
| No send, no external msg | events=[] | events=[] |
| Doctor Screen Recording | warning | warning |
| OCR text extraction | `"既読\nClawGate test 6"` | Text extracted |

## Lessons Learned

1. **LINE Qt window title は常に "LINE"** — conversation-based echo matching は不可
2. **OCR が読む行は必ずしも新メッセージ行ではない** — row_count_delta=0 の場合、lastFrame は既存行
3. **pair/generate 呼出でトークン無効化** — テストでは1コマンドで pair → 即使用する必要あり
4. **CGPreflightScreenCaptureAccess が warning でも OCR 動作** — 以前付与された権限が残っている可能性
