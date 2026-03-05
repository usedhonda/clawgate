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
  ├─ 全幅スキャンで緑行を判定 (10px 以上の緑 → green)
  ├─ 右端レーンで白行を判定 (yCut 用)
  ├─ 緑行を白マスク (255 fill, 拡張なし)
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

### 2. 全幅スキャン: レーンではなく行全体で緑を判定 (P0)

```swift
private static let greenRowThreshold = 10
```

**緑行の判定にレーン（右端数ピクセル）を使わないこと。行全体をスキャンすること。**

#### なぜ

レーン方式では `greenExpandRows = 3`（±3行拡張）が必要だった。
緑バブルの角丸やアンチエイリアスで、レーンにはピクセルが乗らない行があるため。
しかしこの拡張が隣接する白バブル（受信テキスト）に食い込み、OCR が文字化けした。

| 方式 | 緑判定範囲 | 拡張 | 副作用 |
|------|-----------|------|--------|
| レーン方式 (旧) | 右端 3px | ±3行 | 白バブルのテキスト端を侵食 → OCR 文字化け |
| 全幅スキャン (現) | 行全体 | なし | 緑ピクセルがある行 = 送信行 → 正確 |

#### 根本思想

**緑ピクセルがある行 = 送信バブルの行 → 読む必要なし → 白塗り。**

行内に 10px 以上の緑ピクセルがあれば送信行と確定する。
拡張不要、レーン位置チューニング不要。角丸やアンチエイリアスの問題も消える。

#### 早期脱出

```swift
if greenCount >= greenRowThreshold { break }
```

閾値に達した時点で内側ループを抜ける。
緑バブルの行は左端から数十 px 以内で確定するため、パフォーマンス影響は最小。

#### Lane Offset (白行検出用に残存)

```swift
private static let laneOffsetRatio: Double = 0.045
private static let laneHalfWidth = 1
```

`laneOffsetRatio` / `laneHalfWidth` は**緑判定には使わない**。
yCut（入力欄検出）のための白行判定にのみ使用。比率ベースを維持。

#### 2026-03-06 変更

- **症状**: `greenExpandRows = 3` が隣接白バブルに食い込み、OCR が文字化け
- **根本原因**: レーン方式 → 角丸行の未検出 → 拡張で補填 → 過剰マスク
- **修正**: 全幅スキャン + 閾値 10px + 拡張なし
- **教訓**: 「ピクセルがある行を直接判定」が最もシンプルで正確

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
| `greenRowThreshold` | 10 | 全幅スキャンで緑行と判定する最低緑ピクセル数 |
| `laneOffsetRatio` | 0.045 | 白行検出レーン位置 (幅の 4.5%, yCut 用) |
| `laneHalfWidth` | 1 | 白行検出レーン幅 = 3px (center ± 1, yCut 用) |
| `whiteThreshold` | 238 | 白判定: R,G,B 全て > 238 |
| `minBottomWhiteRun` | 8 | 入力欄判定の最低連続白行数 |
| `minAcceptedCutRatioFromTop` | 0.84 | カット位置が上から 84% 未満なら誤検知として棄却 |

---

## Masking Algorithm

```
for each row (y = 0..<height):
    全幅スキャン: 緑ピクセルをカウント (閾値到達で早期脱出)
    if greenCount >= 10 → rowClass = .green, greenRows++
    else:
        laneRange の 3px をサンプル (白行検出, yCut 用)
        if 2/3 以上が white → rowClass = .white
        else → rowClass = .other

for each row:
    if rowClass == .green OR y >= yCut:
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
- [ ] 緑行判定は**全幅スキャン**か？レーン方式に戻していないか？
- [ ] 緑行に拡張 (expand) を入れていないか？（白バブル侵食の原因）
- [ ] 閾値変更時、macmini の実環境で preprocessed.png を確認したか？
- [ ] Python やローカル環境だけでなく、**macmini の ICC プロファイル環境** でテストしたか？
