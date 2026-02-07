# open_conversation: AXRow click instead of Enter

## Date
2026-02-07

## Instruction
LINE send_message API の open_conversation ステップで、検索結果の AXRow をクリックして会話に遷移するよう修正。
以前は `sendSearchEnter()` (CGEvent HID Enter) を使っていたが、Qt の検索結果リストでは Enter だけでは確実に会話遷移しなかった。

## Changes

### `ClawGate/Adapters/LINE/LINEAdapter.swift`
- `open_conversation` ステップのステップ 4-5 を書き換え:
  - 旧: `AXActions.sendSearchEnter()` — CGEvent HID Enter で検索確定
  - 新: AXRow のポーリング待ち (最大 2s) → `surface()` → `clickAtCenter(row)`
- AXRow の検索条件: `role == "AXRow"` かつ `relX < 0.4`（左サイドバー領域）
- `surface()` をクリック直前に再呼出しして最小化防止

### 変更なし
- `rescan_after_navigation` — 既存のポーリングそのまま
- `input_message` — setValue + setFocused そのまま
- `send_message` — sendEnter(pid:) そのまま
- `AXActions.swift` — 変更なし（`clickAtCenter` は既存）

## Result
- API: `ok: true`, HTTP 200
- ウインドウ最小化: 要確認
- 会話遷移: 要確認
- メッセージ入力: 要確認
- Enter 送信: 要確認（既知の問題の可能性）

## Key Decisions
- AXRow に AXPressAction が存在しない（LINE Qt 実装）→ clickAtCenter が唯一の手段
- clickAtCenter は `.cghidEventTap` で HID レベルマウスイベント → アプリが前面なら最小化しない
- `surface()` 再呼出しは安全策（前面確認 + 最小化解除）
