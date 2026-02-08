# トークン認証の完全廃止

**日時**: 2026-02-08 19:45
**作業**: ClawGate からトークン認証を完全に削除

## 背景

ClawGate は `127.0.0.1` のみに bind しており、外部アクセスは不可能。
にもかかわらず、トークン認証 + Keychain + ペアリングフローが存在し:
- dev-deploy / smoke-test のたびにトークンが無効化され OpenClaw が切断
- ペアリングコードの入力が必要
- Keychain がブロッキングダイアログの原因

**方針**: トークン認証を完全廃止。CSRF 防御は Origin ヘッダーチェック（既存）のみ。

## 変更内容

### 削除ファイル
- `ClawGate/Core/Security/BridgeTokenManager.swift`
- `ClawGate/Core/Security/KeychainStore.swift`
- `ClawGate/Core/Security/PairingCodeManager.swift`

### Swift 変更 (7 files)
- `BridgeCore.swift`: tokenManager/pairingManager 削除、checkOrigin() 追加、doctor から token_configured 削除
- `BridgeRequestHandler.swift`: pair ルート削除、isAuthorized ガード削除、CSRF チェック追加
- `BridgeModels.swift`: PairRequest/PairResult/GenerateCodeResult 削除
- `main.swift`: BridgeCore init 簡素化（3パラメータ）
- `MenuBarApp.swift`: ペアリングメニュー/タイマー/トークンコピー削除
- `SettingsView.swift`: トークン表示/再生成 UI 削除
- `BridgeCoreTests.swift`: 認証テスト5件削除、Origin チェックテスト3件追加

### JS プラグイン変更 (4 files)
- `client.js`: X-Bridge-Token 削除、clawgatePair 削除、全関数から token 引数削除
- `gateway.js`: ensureToken 削除、re-pair バックオフ/サーキットブレーカー全削除
- `config.js`: token フィールド削除
- `outbound.js`: token 引数削除

### スクリプト変更 (2 files)
- `smoke-test.sh`: auto-pair テスト削除、認証ヘッダー削除、5テストに再構成
- `integration-test.sh`: ペアリング/認証テスト削除、18テストに再構成

### ドキュメント変更 (3 files)
- `SPEC.md`: Section 4 簡素化、pair エンドポイント削除、doctor 更新
- `CLAUDE.md`: Self-Service Operations から認証ヘッダー削除
- `docs/clawgate-recovery-guide.md`: トークン関連セクション削除・更新

## 検証結果

```
swift build: OK
dev-deploy.sh: Deploy complete!
smoke-test.sh: 5 PASS, 0 FAIL
OpenClaw gateway log:
  - doctor OK (5/5 checks passed)
  - initial cursor=0, skipping 0 existing events
```

## 効果

- デプロイ時のトークン無効化問題が完全に解消
- OpenClaw gateway がペアリングなしで即座に接続可能
- コードベースが約500行削減（Security/ 3ファイル + 各所の認証ロジック）
