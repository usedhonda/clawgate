# PixelDiff / VisionOCR: LINE ウインドウ単体キャプチャ対応

## 日時
2026-02-08 15:28

## 指示
LINE ウインドウの上に別ウインドウが重なった場合の PixelDiff 誤検出と OCR 誤読を修正する。

## 変更内容

### 問題
- `CGWindowListCreateImage(.optionOnScreenOnly, kCGNullWindowID, ...)` は画面上の全レイヤーを合成してキャプチャする
- LINE の上に別ウインドウ（ブラウザ、ターミナル等）が重なると:
  - PixelDiff のハッシュが変わって偽陽性
  - OCR が別ウインドウのテキストを読み取る

### 修正
1. **AXActions.swift**: `findWindowID(pid:)` ヘルパー追加
   - `CGWindowListCopyWindowInfo` で PID の layer=0 ウインドウの CGWindowID を取得
2. **VisionOCR.swift**: `windowID` パラメータ追加（デフォルト `kCGNullWindowID` で後方互換）
   - `windowID != kCGNullWindowID` なら `.optionIncludingWindow` で単体キャプチャ
3. **LINEInboundWatcher.swift**: `doPoll()` で LINE の windowID を取得し、4箇所に渡す
   - AXRow OCR (line 122)
   - PixelDiff CGWindowListCreateImage (line 156)
   - Baseline OCR (line 164)
   - Pixel change OCR (line 177)

### 追加修正
- **smoke-test.sh**: `AUTH` 変数のクォーティング問題を修正
  - 旧: `AUTH="-H X-Bridge-Token:$TOKEN"` → `api $AUTH ...` (word splitting で壊れる)
  - 新: `AUTH_HEADER="X-Bridge-Token: $TOKEN"` → `api -H "$AUTH_HEADER" ...`

## 変更ファイル
- `ClawGate/Automation/AX/AXActions.swift`: findWindowID(pid:) 追加 (line 114-130)
- `ClawGate/Automation/Vision/VisionOCR.swift`: windowID パラメータ追加 (line 12, 34)
- `ClawGate/Adapters/LINE/LINEInboundWatcher.swift`: windowID 取得 + 4箇所渡し (line 55, 122, 155-157, 164, 177)
- `scripts/smoke-test.sh`: AUTH ヘッダーのクォーティング修正 (line 79, 85, 97, 110)

## 検証
- `swift build` 成功（warning のみ、error なし）
- `dev-deploy.sh --skip-plugin` でデプロイ成功
- smoke-test 5/5 PASS
