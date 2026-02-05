# 001 implement-plan

## 指示内容
- AGENTS.mdに従い、提示済みのM0〜M7計画を実装する。

## 実施内容
- Swift Packageを初期化し、`Package.swift` をmacOS + SwiftNIO + UnitTests構成へ更新。
- `AppBridge/` 配下に Core/UI/Automation/Adapters 構成を作成。
- メニューバーUI、設定画面、token管理(Keychain)、Config(UserDefaults)を実装。
- localhost(`127.0.0.1:8765`) HTTP/SSEサーバを実装し、`/v1/health` `/v1/send` `/v1/poll` `/v1/events` `/v1/axdump` を追加。
- `LINEAdapter`、`AXQuery`、`AXActions`、`AXDump`、`RetryPolicy`、`StepLog` を実装。
- docs (`architecture.md`, `troubleshooting.md`, `Tests/IntegrationNotes.md`) を追加。
- Unit test (`EventBusTests`, `BridgeCoreTests`) を追加。

## 課題、検討事項
- LINEのAXセレクタは環境依存が大きく、`/v1/axdump`結果を元に `LineSelectors` のチューニングが必要。
- 受信監視は現状heartbeatイベントの配線まで。実メッセージ差分検知は次の改修でAX読み取りロジック追加が必要。
- SSEの再接続時cursor追跡は最小実装。必要なら`Last-Event-ID`対応を追加する。
- `swift test` はこの実行環境の sandbox 制約（`sandbox-exec: sandbox_apply: Operation not permitted`）で実行不可。ローカル端末での検証が必要。
