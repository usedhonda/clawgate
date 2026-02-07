# InboundWatcher イベント駆動化 — 通知バナー監視 + AXObserver

## 日時
2026-02-07 21:22

## 指示
InboundWatcher をイベント駆動化。通知バナー監視 + AXObserver 検証。

## Phase 0: AXObserver 検証結果

**結論: Qt/LINE は AX 通知を発火する**

`scripts/test-ax-observer.swift` で 60 秒間監視:
- `AXValueChanged` → fire (AXStaticText)
- `AXFocusedUIElementChanged` → fire (AXWindow, AXTextArea)
- `AXCreated` → fire (AXWindow)
- `AXUIElementDestroyed` → fire
- `AXSelectedChildrenChanged` → fire (AXMenuBar, AXMenu)
- `kAXLayoutChangedNotification` → **not fired**
- `kAXRowCountChangedNotification` → **not fired**

注意: Windows=0 の状態で開始したため、AXList に対する通知は登録できなかった。
LINE ウインドウ表示後に再登録すれば `kAXChildrenChanged` 等が fire する可能性あり。

## Phase 1: 通知バナー監視

### 新規ファイル
- `ClawGate/Adapters/LINE/NotificationBannerWatcher.swift`

### 実装
- AXObserver で `com.apple.notificationcenterui` の `kAXWindowCreatedNotification` を監視
- 2 秒間隔のフォールバックポーリング
- バナー AX ツリーから "LINE" アプリ名でフィルタ
- 送信者名 + メッセージテキストを抽出
- fingerprint ベースの重複排除 (10 秒ウインドウ)
- echo suppression (RecentSendTracker)
- EventBus に `source: "notification_banner"` で emit

### 変更ファイル
- `ClawGate/Adapters/LINE/LINEInboundWatcher.swift:138` — `source: "poll"` フィールド追加
- `ClawGate/Core/Config/AppConfig.swift:9` — デフォルトポーリング間隔 3s → 10s
- `ClawGate/main.swift:28-31,37,43` — NotificationBannerWatcher DI 追加

### 通知バナー AX 構造調査
- `com.apple.notificationcenterui` はバナー非表示時 Windows=0
- バナー表示時にウインドウが作成される → AXObserver で検出可能
- バナーの詳細な AX 構造は実際の通知表示時に確認が必要（未実施）

## 検証
- ビルド: 成功
- デプロイ: 成功 (ClawGate Dev 署名)
- ポーリング `source: "poll"`: 正常動作
- echo_message 検出: 送信直後に正常動作
- inbound_message 検出: temporal window 外で正常動作

## 課題
- 通知バナーの実際の AX 構造は外部からのメッセージ受信時にしか確認できない
- DND/Focus モード時はバナー抑制 → ポーリング fallback に依存
- Phase 2 (AXObserver ハイブリッド) は未実装
