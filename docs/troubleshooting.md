# Troubleshooting

## 決定木: 動かないときの診断フロー

```
ClawGateが動かない
│
├─ 1. ClawGateは起動している？
│   └─ NO → `open -a ClawGate` または `swift run ClawGate`
│
├─ 2. メニューバーに🦀アイコンがある？
│   └─ NO → ClawGateがクラッシュした可能性。Console.appでログ確認
│
├─ 3. Accessibility権限は許可されている？
│   │   確認: System Settings > Privacy & Security > Accessibility
│   └─ NO → ClawGateをONにする（変更後は再起動推奨）
│
├─ 4. LINEは起動している？
│   └─ NO → LINEを起動
│
├─ 5. LINEウィンドウは前面に表示されている？
│   │   Qt制約: バックグラウンドではAXツリーが取得できない
│   └─ NO → LINEウィンドウを前面に表示
│
├─ 6. ポート8765は使用可能？
│   │   確認: `lsof -i :8765`
│   └─ 他プロセスが使用中 → そのプロセスを終了
│
├─ 7. トークンは正しい？
│   │   確認: `X-Bridge-Token` ヘッダーの値
│   └─ 不一致 → メニューバー → 「トークンをコピー」で再取得
│
└─ 8. それでも動かない
    └─ `/v1/axdump` でAXツリーを確認
        └─ 予期しない構造 → GitHub issueを作成
```

---

## エラーコード別対処

### `unauthorized`

**原因**: トークンが一致しない

**対処**:
1. メニューバーの🦀 → 「トークンをコピー」
2. `X-Bridge-Token` ヘッダーに正しい値を設定
3. Keychainから直接確認: `security find-generic-password -s com.clawgate.local -a bridge.token -w`

---

### `ax_permission_missing`

**原因**: Accessibility権限がない

**対処**:
1. System Settings > Privacy & Security > Accessibility
2. ClawGateをONにする
3. ClawGateを再起動

---

### `line_not_running`

**原因**: LINEアプリが起動していない

**対処**:
1. LINEを起動
2. 通常のチャットウィンドウを表示

---

### `line_window_missing`

**原因**: LINEウィンドウが取得できない

**対処**:
1. LINEを前面に表示（Qt制約: バックグラウンドではkAXWindowsAttributeがnilを返す）
2. 最小化されている場合は復元

---

### `search_field_not_found`

**原因**: 検索フィールドがAXツリーにない

**対処**:
1. LINEのサイドバーが表示されているか確認
2. `/v1/axdump` でAXツリー構造を確認
3. LineSelectorsがLINEバージョンと一致しているか確認

---

### `message_input_not_found`

**原因**: メッセージ入力欄がAXツリーにない

**対処**:
1. LINEでチャット画面を開いているか確認
2. 入力欄にフォーカスがあるか確認
3. `/v1/axdump` でAXTextAreaの存在を確認

---

## SSEが来ない

**確認手順**:

1. `/v1/events` に接続できているか確認
   ```bash
   curl -N -H "X-Bridge-Token: YOUR_TOKEN" http://127.0.0.1:8765/v1/events
   ```

2. イベントが蓄積されているか確認
   ```bash
   curl -H "X-Bridge-Token: YOUR_TOKEN" http://127.0.0.1:8765/v1/poll
   ```

3. LINEInboundWatcherが動作しているか確認
   - LINEウィンドウが前面にあるか
   - 新着メッセージがあるか

---

## デバッグコマンド

### Doctor（自己診断）

```bash
curl -H "X-Bridge-Token: YOUR_TOKEN" http://127.0.0.1:8765/v1/doctor
```

診断項目:
- `accessibility_permission` - Accessibility権限
- `token_configured` - トークン設定
- `line_running` - LINE起動状態
- `line_window_accessible` - LINEウィンドウ取得可否
- `server_port` - サーバーポート状態

### AXツリーダンプ

```bash
curl -H "X-Bridge-Token: YOUR_TOKEN" http://127.0.0.1:8765/v1/axdump
```

### ヘルスチェック

```bash
curl http://127.0.0.1:8765/v1/health
```

### 現在のコンテキスト

```bash
curl -H "X-Bridge-Token: YOUR_TOKEN" "http://127.0.0.1:8765/v1/context?adapter=line"
```

### ペアリング（トークン取得）

1. メニューバーの🦀 → 「ペアリングコードを生成」をクリック
2. 6桁のコードがクリップボードにコピーされる（有効期限120秒）
3. APIでトークンを取得:

```bash
curl -X POST http://127.0.0.1:8765/v1/pair/request \
  -H "Content-Type: application/json" \
  -d '{"code":"123456","client_name":"my-app"}'
```

レスポンス:
```json
{"ok":true,"result":{"token":"abc123..."}}
```

**注意**: ブラウザからのリクエスト（Origin ヘッダー付き）は CSRF 対策のため拒否されます。

---

## 関連ドキュメント

- [OpenClaw統合ガイド](./openclaw-integration.md) - プロンプト例・クイックスタート
- [アーキテクチャ](./architecture.md) - 内部構造
