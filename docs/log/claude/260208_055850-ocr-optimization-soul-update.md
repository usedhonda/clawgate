# OCR 最適化 + ちー強化

**日時**: 2026-02-08 05:58

## 変更内容

### 1. VisionOCR バッチメソッド追加
- **ファイル**: `ClawGate/Automation/Vision/VisionOCR.swift:51-58`
- `extractText(from: [CGRect], padding:)` メソッド追加
- 複数矩形を union → 1回のキャプチャで OCR
- 効果: N行 × 300ms → 1回 × 300ms

### 2. LINEInboundWatcher バッチ OCR 化
- **ファイル**: `ClawGate/Adapters/LINE/LINEInboundWatcher.swift:120-121`
- for ループ → `VisionOCR.extractText(from: newRowFrames, padding: 4)` に置換

### 3. PixelDiff OCR 範囲縮小
- **ファイル**: `ClawGate/Adapters/LINE/LINEInboundWatcher.swift:172-184`
- 全チャットエリア OCR → 最後の AXRow の下端以降のみに限定
- lastRowSnapshot を使って新メッセージ領域を推定
- フォールバック: bottomHalf（既存ロジック）

### 4. SOUL.md 行動指針追加
- **ファイル**: `~/.openclaw/workspace/SOUL.md`
- 「得意技」セクション追加（結論ファースト、web_search 積極活用、箇条書き等）

### 5. LINE ウインドウ自動リサイズ
- **ファイル**: `ClawGate/Automation/AX/AXActions.swift:113-155`
- `setWindowPosition`, `setWindowSize`, `setWindowFrame`, `optimalWindowFrame` 追加
- 画面の65%幅 x 85%高さ（最大1200x900）を自動計算
- **ファイル**: `ClawGate/Adapters/LINE/LINEAdapter.swift:83-100`
- `optimize_window` ステップを `surface_line` の後に追加
- 設定後にフレーム読み返しで確認、80%未満なら warning
- **効果**: チャットリスト 384x501 -> 825x660（面積2.8倍）

## 未適用
- `minimumTextHeightFraction`: macOS 15.7 / Swift 6.2 の VNRecognizeTextRequest に存在しないため除外

## ビルド結果
- `swift build`: 成功 (11.60s)
- re-sign: ClawGate Dev 署名
- doctor: 6/6 PASS
- Gateway: 再起動済み
