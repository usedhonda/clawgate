# InboundWatcher E2E Test & Fix

## Date: 2026-02-07

## Summary

LINEInboundWatcher の E2E テストを実施。テキストベースの検出方式が動作しない根本原因を特定し、
AXRow フレーム構造ベースの検出方式に書き換えた。前面・背面の両方で動作確認済み。

## Issue: LINE Qt AX bridge does not expose text

### Fact
- LINE (Qt-based) の AXStaticText ノードは全属性が空:
  - `AXTitle = ""`
  - `AXDescription = ""`
  - `AXValue = <error: -25212>`
  - `AXNumberOfCharacters = 0`
  - `AXSelectedText = <error: -25212>`
- Parameterized attributes: `AXReplaceRangeWithText`, `AXLineForIndex` のみ (AXStringForRange なし)
- すべての AXStaticText/AXRow で同じ結果

### Impact
- 旧 InboundWatcher はテキスト差分検出 → 常に空文字同士の比較 → 初回のみ発火して以降沈黙
- テキスト抽出は AX 経由では不可能 (OCR or 別手段が必要)

## Fix: Frame-based detection

### Changed files
- `ClawGate/Adapters/LINE/LINEInboundWatcher.swift` — 全面書き換え

### New detection logic
1. チャットエリアの AXList を特定 (AXRow 子要素が最も多い AXList)
2. AXRow のフレーム (CGRect) リストをスナップショット
3. 行数変化 or 最下部行の Y 座標/高さ変化 → `inbound_message` イベント発行
4. `focusedWindow ?? windows().first` で背面動作にも対応

### Test results

| Test | Result | Detail |
|------|--------|--------|
| Test A: LINE foreground | PASS | row_count_delta=0, total_rows=11, 送信後3秒以内に検出 |
| Test B: LINE background | PASS | Finder 前面でも検出動作 (windows().first fallback) |

### Event payload example
```json
{
    "type": "inbound_message",
    "adapter": "line",
    "payload": {
        "text": "",
        "conversation": "LINE",
        "row_count_delta": "0",
        "total_rows": "11"
    }
}
```

## Limitations (documented, not addressed)
- `text: ""` — テキスト抽出不可 (LINE Qt AX 制限)
- Echo suppression なし (自分の送信も検出する)
- `.last` → tail diff なし (複数メッセージ同時到着は1イベント)
- ウインドウタイトルは "LINE" 固定 (会話名が取得できない)

## AI Discussion
- ChatGPT: AXObserver + row identity diff 推奨、parameterized attributes を試すべき
- Gemini: hidden attribute dump → Y-coordinate tracking → Vision OCR
- 結論: parameterized attrs も空 → frame-based detection が最適解
