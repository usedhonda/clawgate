# ClaudeCode向け引き継ぎ（AppBridge）

## 1) 現在の到達点
- M0〜M2相当の土台は実装済み。
- メニューバー常駐アプリとして起動し、Settingsからtoken再生成・ログ設定・poll間隔設定が可能。
- localhost API実装済み:
  - `GET /v1/health`
  - `POST /v1/send`（token必須）
  - `GET /v1/poll`（token必須）
  - `GET /v1/events`（SSE, token必須）
  - `GET /v1/axdump`（token必須）
- LINE送信フローは実装済みだが、AXセレクタは環境依存のため実機チューニング前提。
- 受信イベントは現状heartbeatの配線まで（実メッセージ差分検知は未実装）。

## 2) 主要ファイル
- エントリポイント: `AppBridge/main.swift`
- UI: `AppBridge/UI/MenuBarApp.swift`, `AppBridge/UI/SettingsView.swift`
- サーバ: `AppBridge/Core/BridgeServer/BridgeServer.swift`, `AppBridge/Core/BridgeServer/BridgeRequestHandler.swift`, `AppBridge/Core/BridgeServer/BridgeCore.swift`
- 認証/設定: `AppBridge/Core/Security/BridgeTokenManager.swift`, `AppBridge/Core/Config/AppConfig.swift`
- イベント: `AppBridge/Core/EventBus/EventBus.swift`
- LINE自動化: `AppBridge/Adapters/LINE/LINEAdapter.swift`, `AppBridge/Adapters/LINE/LineSelectors.swift`
- AX基盤: `AppBridge/Automation/AX/AXQuery.swift`, `AppBridge/Automation/AX/AXActions.swift`, `AppBridge/Automation/AX/AXDump.swift`
- テスト: `Tests/UnitTests/BridgeCoreTests.swift`, `Tests/UnitTests/EventBusTests.swift`

## 3) 直近で着手すべき順序（推奨）
1. LINE実機で `GET /v1/axdump` を取得し、`LineSelectors` を調整。
2. `LINEAdapter.sendMessage` の再スキャン箇所を増やし、検索後のUI変化に追従。
3. 受信監視を heartbeat から「1トーク固定の差分検知」へ置換。
4. SSEに `Last-Event-ID` 対応を追加し、再接続時の欠落を防ぐ。
5. エラーコードと `failed_step` の網羅テストを追加。

## 4) 実行・確認コマンド
```bash
swift run AppBridge
curl http://127.0.0.1:8765/v1/health
```

token取得後の例:
```bash
TOKEN="<settingsに表示されるtoken>"
curl -H "X-Bridge-Token: $TOKEN" http://127.0.0.1:8765/v1/poll
curl -N -H "X-Bridge-Token: $TOKEN" http://127.0.0.1:8765/v1/events
curl -H "X-Bridge-Token: $TOKEN" http://127.0.0.1:8765/v1/axdump
```

送信API例:
```bash
curl -X POST http://127.0.0.1:8765/v1/send \
  -H "Content-Type: application/json" \
  -H "X-Bridge-Token: $TOKEN" \
  -d '{
    "adapter":"line",
    "action":"send_message",
    "payload":{
      "conversation_hint":"自分メモ",
      "text":"hello from AppBridge",
      "enter_to_send":true
    }
  }'
```

## 5) 既知の制約
- この作業環境では sandbox 制約により `swift test` を実行できていない。
- `Sources/AppBridge/AppBridge.swift` は `swift package init` の残骸（未使用）。必要なら削除。
- `LINEAdapter` は初回取得したAXノードを使い回しているため、画面遷移後の再探索が必要。
- CGEvent fallbackは環境によって追加権限が必要。

## 6) Intel Mac mini対応メモ
- `Package.swift` は `swift-tools-version: 5.9`, `macOS(.v12)` に設定済み。
- Intel実機（x86_64）でのビルド/実行を前提化済み。
- Apple SiliconからIntel向けビルドする場合:
```bash
swift build -Xswiftc -target -Xswiftc x86_64-apple-macos12.0
```

## 7) ドキュメント参照
- 全体設計: `docs/architecture.md`
- 障害対応: `docs/troubleshooting.md`
- 手動統合チェック: `Tests/IntegrationNotes.md`
- 作業ログ: `docs/log/codex/001-implement-plan.md`, `docs/log/codex/002-intel-compatibility.md`
