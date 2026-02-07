# Pixel Diff: Chat Area Only (2026-02-07)

## 指示
ピクセル変化検出の精度改善 — チャット領域限定 + 最下部フォーカス

## 問題
- サイドバーの会話名変化、ツールバーのバッジ点滅でハッシュが変わり誤検出
- ウインドウ全体をキャプチャ・ハッシュ・OCR していたのが原因

## 変更

### `ClawGate/Adapters/LINE/LINEInboundWatcher.swift` (L149-198)

| Before | After |
|--------|-------|
| `windowFrame`（ウインドウ全体）でハッシュ計算 | `chatListFrame`（AXList bounds）の下半分でハッシュ計算 |
| `windowFrame` で OCR | `chatListFrame` 全体で OCR |

具体的な変更:
1. `AXQuery.copyFrameAttribute(window)` → `AXQuery.copyFrameAttribute(chatList)`
2. ハッシュ計算: `chatListFrame` の下半分（`bottomHalf`）のみキャプチャ
3. OCR: `chatListFrame` 全体で実行（テキスト全文が必要）
4. `chatList` は L66 で既に取得済み → 新規 AX クエリ不要

## 検証
- ビルド成功
- `ClawGate Dev` で再署名、AX 権限維持
- doctor: 全 6 チェック OK
- axdump で AXList 確認: chat list = {x:1202, y:292, w:384, h:501, rows:30}

## 効果
- サイドバー領域（x:889, w:312）が完全にハッシュ対象外
- ツールバー/ヘッダー領域も除外
- ハッシュは最下部のみ → スクロール位置変化や上部既読マーク更新を無視
