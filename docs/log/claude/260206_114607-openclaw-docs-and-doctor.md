# OpenClaw統合ドキュメント & Doctor/Pairing機能実装

**日時**: 2026-02-06 11:46:07 - 11:52
**タスク**: ClawGate導入簡易化 & OpenClaw向けドキュメント

## 実施内容

### Phase 1: ドキュメント作成

| ファイル | 内容 |
|----------|------|
| `docs/openclaw-integration.md` | OpenClaw向け統合ガイド（Prompt-First設計） |
| `docs/local-only-manifest.json` | プライバシー証明用マニフェスト |
| `docs/troubleshooting.md` | 決定木形式に更新 |

### Phase 2: Doctor機能実装

| ファイル | 変更内容 |
|----------|----------|
| `ClawGate/Core/BridgeServer/BridgeModels.swift` | `DoctorCheck`, `DoctorReport`, `DoctorSummary` モデル追加 |
| `ClawGate/Core/BridgeServer/BridgeCore.swift` | `doctor()` メソッド追加 |
| `ClawGate/Core/BridgeServer/BridgeRequestHandler.swift` | `/v1/doctor` エンドポイント追加 |
| `ClawGate/Core/Security/BridgeTokenManager.swift` | `hasValidToken()` メソッド追加 |

### Phase 3: ペアリング強化

| ファイル | 変更内容 |
|----------|----------|
| `ClawGate/Core/Security/PairingCodeManager.swift` | 新規作成 - 6桁コード生成、TTL 120秒、1回使い切り |
| `ClawGate/Core/BridgeServer/BridgeModels.swift` | `PairRequest`, `PairResult` モデル追加 |
| `ClawGate/Core/BridgeServer/BridgeCore.swift` | `pair()` メソッド追加、Origin検証（CSRF対策） |
| `ClawGate/Core/BridgeServer/BridgeRequestHandler.swift` | `/v1/pair/request` エンドポイント追加 |
| `ClawGate/UI/MenuBarApp.swift` | メニューバーに🦀アイコン、ペアリングコード生成/表示、トークンコピー機能 |
| `ClawGate/main.swift` | `PairingCodeManager` 統合 |

## セキュリティ機能

- **ワンタイムコード**: 6桁、120秒TTL、1回限り有効
- **Origin検証**: ブラウザからのリクエスト（Origin ヘッダー付き）を拒否
- **CSRF対策**: ペアリングコードなしではトークン取得不可

## 検証結果

- ビルド: 成功（warning 2件は既知の非推奨警告）
- テスト: 43件すべてパス

### Phase 4: 配布整備

| ファイル | 内容 |
|----------|------|
| `ClawGate.app/Contents/Info.plist` | App bundle設定（bundleId: com.clawgate.app） |
| `ClawGate.entitlements` | サンドボックス無効（Accessibility API使用のため） |
| `scripts/release.sh` | ビルド→署名→DMG→Notarization→Staple→GitHub Release |
| `.local/release.md` | Apple認証情報テンプレート（.gitignore済み） |

## リリース手順

```bash
# .local/release.md に APP_PASSWORD を設定後
./scripts/release.sh          # ビルド＆Notarize
./scripts/release.sh --publish # + GitHub Release作成
```

## 今後の作業

- Homebrew Tap リポジトリ作成（`usedhonda/homebrew-clawgate`）
- アイコン作成（ClawGate.app/Contents/Resources/AppIcon.icns）
