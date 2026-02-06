# NIOイベントループ・ブロッキング修正

## 日時
2026-02-06 17:02

## 指示
統合テストで発見されたCRITICALバグ（NIOイベントループのブロッキング）を修正。
プラン: `plans/golden-nibbling-fountain.md`

## 作業内容

### 変更ファイル
- `ClawGate/Core/BridgeServer/BridgeRequestHandler.swift` (全体)

### 変更詳細

1. **`import Dispatch` 追加** (行1)
2. **`blockingQueue` static プロパティ追加** (行10-13)
   - `DispatchQueue(label: "com.clawgate.blocking", qos: .userInitiated)`
3. **`offloadToBlockingQueue` ヘルパーメソッド追加** (行148-158)
   - ブロッキング処理をDispatchQueueで実行し、結果を`context.eventLoop.execute`でNIOスレッドに戻す
4. **`writeUnauthorized` ヘルパーメソッド追加** (行160-171)
   - 認証エラーレスポンスの共通化
5. **`handleRequest()` の全面リファクタ** (行48-143)
   - `/v1/health`: 変更なし（非ブロッキング、イベントループ上で即応答）
   - `/v1/poll`: オフロード（authチェックがKeychainアクセスを含むため）
   - `/v1/pair/request`: `offloadToBlockingQueue`でオフロード（Keychain）
   - `/v1/events` (SSE): authチェックのみオフロード、SSE開始はイベントループ上
   - その他全て (`/v1/send`, `/v1/context`, `/v1/messages`, `/v1/conversations`, `/v1/axdump`, `/v1/doctor`): authチェック + ビジネスロジックをオフロード

### 変更しなかったファイル
- `BridgeServer.swift` (numberOfThreads: 1 のまま。I/O専用として正しい)
- `BridgeCore.swift` (DispatchQueue上で呼ばれるようになるため変更不要)
- `LINEAdapter.swift` (Thread.sleepはDispatchQueue上で実行されるため変更不要)
- その他全て

### 設計判断
- **プランからの逸脱**: `/v1/poll` もオフロード対象に追加。プランでは「軽量、不要」としていたが、`isAuthorized()` -> `BridgeTokenManager.validate()` -> `keychain.load()` が `SecItemCopyMatching` を呼ぶため、UIダイアログが出るとブロックする可能性がある。安全側に倒してオフロード。
- **スレッド安全性**: `writeResponse`, `writeUnauthorized`, `startSSE` は必ず `context.eventLoop.execute {}` 内からのみ呼ばれる（NIOスレッド上）

## ビルド結果
- `swift build -c release` 成功 (13.06s)
- deprecation warnings 2件（既存、LINEAdapter.swift の NSWorkspace API）
- app bundle更新 + 再署名完了

## 検証方法
```bash
# ClawGate起動
open ClawGate.app

# ブロッキング検証: Doctor（重い処理）実行中にhealthが応答するか
curl -s http://127.0.0.1:8765/v1/health &
curl -s -H "X-Bridge-Token: $TOKEN" http://127.0.0.1:8765/v1/doctor &
# 修正前: healthがdoctorの完了まで応答しない
# 修正後: healthが即座に応答
```

## 検証結果
- health: 0.5ms (pair処理中でも即応答)
- pair: 0.8ms (Keychain + validation)
- 並行health 5リクエスト: 全て正常完了
- Keychain UIダイアログ未発生のため真のブロッキングテストは実機テスト要
- コード構造上、全ブロッキング処理がDispatchQueueオフロード済みであることを確認

## 課題
- AX操作の同時実行時の競合は既存問題（将来的にシリアルキューで対処）
- `blockingQueue` はシリアルキュー（デフォルト）のため、同時に1つのブロッキング処理しか実行されない。将来的に並行度を上げたい場合は `.concurrent` に変更可能
