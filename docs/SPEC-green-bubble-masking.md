# SPEC: Green Bubble Masking (VisionOCR Preprocessing)

## Purpose

LINE の OCR パイプラインで、自分が送信した緑バブル（outgoing messages）を白マスクして
Vision OCR に渡す。これにより送信済みテキストが inbound として再検出されるのを防ぐ。

**このマスキングが壊れると、自分の送信メッセージが受信として検出され、
Chi がそれに返答し、その返答がまた検出される「エコーループ」が発生する。**

---

## Architecture

```
Screen Capture (CGWindowListCreateImage)
  ↓
Anchor Crop (固定比率で会話領域を切り出し)
  ↓
preprocessInboundImage()    ← この関数がマスキングを行う
  ├─ CGContext にピクセル展開
  ├─ 右端レーンで行分類 (green / white / other)
  ├─ 緑行 ±3px を白マスク (255 fill)
  └─ 下部白領域でカット (入力欄除去)
  ↓
Vision OCR (マスク済み画像)
```

**File**: `ClawGate/Automation/Vision/VisionOCR.swift` — `preprocessInboundImage()`

---

## Critical Invariants

### 1. Color Space: 画像のオリジナルを使う (P0)

```swift
space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
```

**絶対に `CGColorSpaceCreateDeviceRGB()` 単体で使わないこと。**

#### なぜ

macmini のディスプレイは ICC プロファイル（例: Panasonic-TV）を持つ。
`CGWindowListCreateImage` が返す CGImage はそのプロファイル付き。
`CGContext` を `deviceRGB` で作ると、ピクセル描画時に ICC → deviceRGB の色空間変換が発生し、
ピクセル値がシフトする。

| 条件 | R | G | B | `isOutgoingGreenPixel` |
|------|---|---|---|----------------------|
| PNG 生読み (Python) | 195 | 246 | 157 | **pass** ✓ |
| `image.colorSpace` (正) | 195 | 246 | 157 | **pass** ✓ |
| `deviceRGB` 変換後 | ~199 | ~241 | ~161 | 閾値ギリギリ or **fail** ✗ |

変換後の値は `g > r + 10` や `g > b + 16` の閾値を外れることがあり、
greenRows ≈ 0 になって**マスキングが完全に無効化**される。

#### 2026-03-05 インシデント

- **症状**: エコーループ（LINE で自分のメッセージが無限に再検出・返答される）
- **根本原因**: `CGColorSpaceCreateDeviceRGB()` による色空間変換
- **修正**: `image.colorSpace ?? CGColorSpaceCreateDeviceRGB()`
- **教訓**: デバイス依存の色空間変換は肉眼では分からない微小なシフトだが、
  ピクセル閾値判定には致命的

### 2. Lane Offset: 比率ベース (画像幅の 4.5%)

```swift
private static let laneOffsetRatio: Double = 0.045
// 実際のオフセット = max(16, Int(Double(width) * laneOffsetRatio))
```

**固定ピクセル値にしないこと。**

#### なぜ

- preprocessing に渡されるのは全ウィンドウ画像ではなく **アンカークロップ**
- クロップ幅はディスプレイスケール (2x/3x) やウィンドウサイズに依存
- 固定ピクセル (例: 16px, 38px) だと、スケールによって緑バブル領域に届かない

| 画像幅 | 4.5% offset | laneX | 備考 |
|--------|-------------|-------|------|
| 1590px (2x crop) | 71px | 1519 | 現行の主要ケース |
| 795px (1x crop) | 35px | 760 | |
| 2400px (3x full) | 108px | 2292 | |

#### 最低床 (floor)

```swift
max(16, Int(Double(width) * laneOffsetRatio))
```

16px の最低床は、極端に小さい画像でもクラッシュしないためのガード。

### 3. Green Pixel 閾値

```swift
private static func isOutgoingGreenPixel(r: Int, g: Int, b: Int) -> Bool {
    g > 130 && g > r + 10 && g > b + 16
}
```

| 条件 | 意味 |
|------|------|
| `g > 130` | 最低限の緑強度 |
| `g > r + 10` | 赤より明確に緑が強い |
| `g > b + 16` | 青より明確に緑が強い |

**LINE の緑バブル**: RGB ≈ (195, 246, 157) — 全条件を余裕で通過。

これらの閾値は **色空間がオリジナルである前提** で設計されている。
deviceRGB 変換が入ると (199, 241, 161) 等にシフトし、マージンが縮小する。

---

## Parameters Summary

| パラメータ | 値 | 意味 |
|-----------|-----|------|
| `laneOffsetRatio` | 0.045 | 画像右端からの検出レーン位置 (幅の 4.5%) |
| `laneHalfWidth` | 1 | レーン幅 = 3px (center ± 1) |
| `greenExpandRows` | 3 | 緑行の上下 ±3 行もマスク対象 |
| `whiteThreshold` | 238 | 白判定: R,G,B 全て > 238 |
| `minBottomWhiteRun` | 8 | 入力欄判定の最低連続白行数 |
| `minAcceptedCutRatioFromTop` | 0.84 | カット位置が上から 84% 未満なら誤検知として棄却 |

---

## Masking Algorithm

```
for each row (y = 0..<height):
    laneRange の 3px をサンプル
    if 2/3 以上が green → rowClass = .green, greenRows++
    elif 2/3 以上が white → rowClass = .white
    else → rowClass = .other

expandedMask = green行の ±3行を true に拡張

for each row:
    if expandedMask[y] == true OR y >= yCut:
        row 全体を 255 (白) で塗りつぶし

return マスク済み画像
```

---

## Debug Output

`/tmp/clawgate-ocr-debug/` に各フレームのデバッグ情報が保存される:

| ファイル | 内容 |
|---------|------|
| `raw.png` | キャプチャ直後の全画面画像 |
| `anchor.png` | アンカークロップ後の画像 (前処理前) |
| `preprocessed.png` | マスキング後の画像 (OCR に渡される) |
| `meta.json` | フレームのメタデータ (anchor 座標、separator 情報) |
| `latest-pipeline.json` | 最新フレームの全パイプライン状態 |

### 正常時の確認方法

```bash
# macmini から最新フレームを取得
scp macmini:/tmp/clawgate-ocr-debug/<latest>/anchor.png /tmp/
scp macmini:/tmp/clawgate-ocr-debug/<latest>/preprocessed.png /tmp/

# Python で緑ピクセル比較
python3 -c "
from PIL import Image; import numpy as np
a = np.array(Image.open('/tmp/anchor.png'))
p = np.array(Image.open('/tmp/preprocessed.png'))
green_a = ((a[:,:,1] > 130) & (a[:,:,1] > a[:,:,0].astype(int) + 10) & (a[:,:,1] > a[:,:,2].astype(int) + 16)).sum()
green_p = ((p[:,:,1] > 130) & (p[:,:,1] > p[:,:,0].astype(int) + 10) & (p[:,:,1] > p[:,:,2].astype(int) + 16)).sum()
print(f'anchor green: {green_a}, preprocessed green: {green_p}, reduction: {(1-green_p/max(1,green_a))*100:.1f}%')
"
```

**期待値**: preprocessed の緑ピクセルが anchor より大幅に少ない (90%+ 減少)。

---

## Modification Checklist

この領域を変更する前に確認:

- [ ] `CGContext` の `space:` パラメータに `image.colorSpace` を使っているか？
- [ ] レーンオフセットは比率ベース (`laneOffsetRatio`) か？固定ピクセルに戻していないか？
- [ ] 閾値変更時、macmini の実環境で preprocessed.png を確認したか？
- [ ] Python やローカル環境だけでなく、**macmini の ICC プロファイル環境** でテストしたか？
