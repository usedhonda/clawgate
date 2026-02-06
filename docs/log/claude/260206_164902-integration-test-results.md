# ClawGate + OpenClaw 統合検証テスト結果

**日時**: 2026-02-06 16:49
**環境**: macOS, OpenClaw gateway (PID 16312, port 18789), LINE (PID 412)
**制約**: Mac本体UI操作不可（リモート実行のみ）

---

## テスト結果サマリー

| Phase | 計画 | PASS | FAIL | SKIP | ブロッカー |
|-------|------|------|------|------|-----------|
| Phase 0: 環境確認 | 3 | 2 | 0 | 1 | XCTest不可（CommandLineToolsのみ） |
| Phase 1: 起動 & 認証 | 9 | 6 | 0 | 3 | Keychainブロッキング、UIペアリング |
| Phase 2: Read API | 5 | 0 | 0 | 5 | トークン認証不可 |
| Phase 3: Send API | 5 | 0 | 0 | 5 | トークン認証不可 |
| Phase 4: イベント | 4 | 0 | 0 | 4 | トークン認証不可 |
| Phase 5: OpenClaw | 4 | 1 | 0 | 3 | UI操作必要 |
| Phase 6: エラー | 3 | 0 | 0 | 3 | UI操作必要 |
| **合計** | **33** | **9** | **0** | **24** | |

---

## Phase 0: 環境前提条件の確認

### T0.1 プロセス確認 — PASS
- OpenClaw gateway: 稼働中 (PID 16312)
- LINE: 稼働中 (PID 412)
- Port 8765: 未使用（ClawGate未起動時点）

### T0.2 ClawGateバイナリ確認 — PASS
- `Mach-O universal binary with 2 architectures: [x86_64] [arm64]`

### T0.3 ユニットテスト — SKIP
- `no such module 'XCTest'` — CommandLineToolsのみでXcode未インストール
- `swift test` はXCTestモジュールが必要
- メインバイナリのビルド自体は成功（警告2件: deprecated API）

---

## Phase 1: ClawGate起動 & 基本動作

### T1.1 ClawGate起動 — PASS（再署名後）
- 初回起動時 `RBSRequestErrorDomain Code=5` エラー
- `spctl -a -vv` で `invalid Info.plist (plist or signature have been modified)` 判明
- **対処**: `codesign --force --sign - --deep --entitlements ClawGate.entitlements` で再署名
- 再署名後、正常起動 (PID 54747 → 56924)

### T1.2 Accessibility権限 — SKIP
- UI確認不可

### T1.3 ヘルスチェック — PASS
```json
{"ok": true, "version": "0.1.0"}
```
HTTP 200

### T1.4 Doctor自己診断 — SKIP
- Keychainアクセスがブロッキング（後述のBUG-001）
- Doctorのリクエスト自体がNIOイベントループをブロック（BUG-002）

### T1.5 認証なしリクエスト 401 — PASS
- `/v1/doctor` → HTTP 401, `unauthorized`

### T1.6 不正トークン 401 — PASS
- `X-Bridge-Token: invalid_token_12345` → HTTP 401

### T1.7 ペアリングフロー — SKIP
- UI操作必要（メニューバーからのコード生成）

### T1.8 無効コードの拒否 — PASS
```json
{"ok": false, "error": {"code": "invalid_pairing_code", "failed_step": "validate_code"}}
```
HTTP 401

### T1.9 CSRF保護 — PASS
```json
{"ok": false, "error": {"code": "browser_origin_rejected", "details": "Origin header detected: http://evil.example.com"}}
```
HTTP 403

---

## 追加テスト（計画外）

### 全認証保護エンドポイントの401テスト — PASS
| エンドポイント | 認証なし |
|---|---|
| `/v1/send` | 401 |
| `/v1/context` | 401 |
| `/v1/messages` | 401 |
| `/v1/conversations` | 401 |
| `/v1/poll` | 401 |
| `/v1/axdump` | 401 |
| `/v1/events` | 401 |

### ペアリング追加テスト — PASS
| テスト | 結果 |
|---|---|
| 空コード | `invalid_pairing_code` |
| 不正JSON | `invalid_json` + 詳細エラー |
| 必須フィールド欠落 | `invalid_json` (デコードエラー) |
| Refererのみ（Originなし）| CSRF未ブロック→`invalid_pairing_code` |

### OpenClaw gateway確認 — PASS
- Port 18789で応答あり（WebUI HTML返却）

---

## 発見されたバグ・問題

### BUG-001: Keychainアクセスがイベントループをブロック [CRITICAL]
- **場所**: `BridgeCore.swift:24-26` (`isAuthorized`)
- **現象**: `SecItemCopyMatching` がUIダイアログ表示を待ってブロック
- **影響**: 認証が必要な全エンドポイントが無応答になる
- **再現**: ad-hoc署名のアプリが、`security`コマンドで作成されたKeychainアイテムにアクセスする際にmacOSが確認ダイアログを表示し、イベントループが停止
- **対策**: Keychain操作を別スレッドで実行するか、NIOEventLoop外で処理

### BUG-002: AXクエリがNIOイベントループをブロック [CRITICAL]
- **場所**: `BridgeCore.swift:74, 107, 138, 169, 206`
- **現象**: `/v1/doctor`, `/v1/axdump`, `/v1/send`, `/v1/context`, `/v1/messages` などでAXクエリが同期実行
- **影響**: AXクエリ中は全HTTPリクエストが停止（health含む）
- **根本原因**: `BridgeServer.swift:7` で `numberOfThreads: 1` のシングルスレッドイベントループ

### BUG-003: Thread.sleep がイベントループ上で実行 [HIGH]
- **場所**: `LINEAdapter.swift:49, 136`
- **現象**: `Thread.sleep(forTimeInterval: 0.5)` がNIOイベントループをブロック
- **影響**: sendMessage実行中の500ms×N回、全リクエストが停止

### BUG-004: HTTPメソッド不一致が401を返す [LOW]
- **場所**: `BridgeRequestHandler.swift:42-126`
- **現象**: `GET /v1/pair/request`, `POST /v1/health` などが404/405でなく401を返す
- **原因**: ルーティングがmethod+path完全一致→認証→not_foundの順で、method不一致はauth fallthrough
- **影響**: クライアントが認証エラーとメソッドエラーを区別できない

### BUG-005: EventBusのデッドロックリスク [MEDIUM]
- **場所**: `EventBus.swift:41-47`
- **現象**: ロック保持中にコールバックを実行し、コールバック内でeventLoop.executeに投げる
- **条件**: イベントループがEventBusのロック待ちの場合にデッドロック

### BUG-006: LINEInboundWatcherとsendMessageの同時AXアクセス [MEDIUM]
- **場所**: `LINEInboundWatcher.swift:34-72`, `LINEAdapter.swift`
- **現象**: タイマーポーリングとHTTPリクエストが同時にLINEのAXツリーにアクセス
- **影響**: AXツリーの不整合やクラッシュの可能性

---

## 推奨修正（優先順）

1. **全AX操作をバックグラウンドスレッドプールに移動** — BUG-001, BUG-002の根本対策
2. **NIOイベントループのスレッド数を増やす** — `numberOfThreads: System.coreCount`
3. **AX操作にタイムアウトラッパーを追加**（最大5秒）
4. **Thread.sleepを適切な非同期waitに置き換え** — BUG-003
5. **AXアクセスのシリアライゼーションロック追加** — BUG-006
6. **ルーティングでメソッド不一致をauth前にチェック** — BUG-004

---

## 次回実施事項（Mac UI操作可能時）

1. Keychainダイアログを「常に許可」で承認
2. T1.2: Accessibility権限確認
3. T1.4: Doctor自己診断
4. T1.7: ペアリングフロー→トークン取得
5. Phase 2全テスト（Read API）
6. Phase 3全テスト（Send API）
7. Phase 4全テスト（イベントシステム）
8. Phase 5: OpenClaw連携テスト
9. Phase 6: エラーハンドリングテスト

---

## 変更ファイル

なし（テストのみ、コード変更なし）
