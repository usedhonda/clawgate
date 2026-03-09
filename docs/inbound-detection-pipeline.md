# LINE Inbound Detection Pipeline

ClawGate が LINE の受信メッセージを検出して AI に届けるまでの一連のアルゴリズム詳解。

---

## 概要フロー

```
LINE 画面
  ↓ poll (1s間隔)
[1] Signal Collection
    ├─ Structural Signal (AX row count)
    └─ Pixel Signal
         ├─ Image hash diff
         ├─ Burst OCR (VisionOCR)
         ├─ Text Cursor Truncation  ← 新機能
         └─ extractDeltaText
  ↓
[2] Fusion Engine (スコア合算 → 閾値判定)
  ↓ shouldEmit=true のみ通過
[3] Sanitize (空テキスト除去)
  ↓
[4] Dedup (Swift 側)
    ├─ Fingerprint dedup (20s window)
    └─ Line Memory dedup + Fuzzy dedup (75s window)
  ↓
[5] EventBus → gateway.js (plugin 側)
  ↓
[6] Dedup (gateway 側)
    ├─ Plugin Echo Guard (10 min window)
    ├─ Short dedup (20s window)
    ├─ Common dedup (20s window)
    └─ Burst Coalesce (1.5s バッファ)
  ↓
[7] handleInboundMessage → AI へ転送
```

---

## 1. OCR パイプライン (VisionOCR.swift)

### キャプチャ

```swift
CGWindowListCreateImage(screenRect, .optionIncludingWindow, windowID, [.bestResolution])
```

- `windowID` 指定でウィンドウ単体をキャプチャ → 他ウィンドウで隠れても正確に取得できる
- Screen Recording 権限なし → `width == 0` → nil を返す

### Inbound 前処理 (`preprocessInboundImage`)

LINE のチャット画面を前提とした混合方式:

```
行全体をスキャンして緑行を判定
  └─ 緑ピクセルが 10px 以上ある行 → 自分（送信済み）のバブル行

画像右端から幅の 4.5% の垂直ライン（3px幅）で白行を判定
  └─ 白ピクセル多数決 → 入力欄・セパレータ候補
```

> **詳細仕様**: [SPEC-green-bubble-masking.md](SPEC-green-bubble-masking.md) を参照。
> 特に色空間、全幅スキャン、白行レーン判定の不変条件は必読。

**処理手順**:
1. CGContext を**画像のオリジナル色空間** (`image.colorSpace`) で作成（deviceRGB 変換禁止）
2. 行全体を走査し、緑ピクセルが 10px 以上ある行を送信済みバブル行 (`.green`) と判定
3. 緑行以外についてのみ、右端 3px レーンの多数決で白/その他を判定
4. `findBottomCutY`: 画面下部の連続白行 (≥8行) を入力欄セパレータと判定 → そこ以降を除去
   - `minAcceptedCutRatioFromTop = 0.84`: 上から 84% 未満の位置のカットは誤検知防止でスキップ
5. 緑行のみを白マスク（拡張なし）
6. マスク済み画像で Vision OCR を実行

**OCR 設定**:
```swift
request.recognitionLevel = .accurate
request.recognitionLanguages = ["ja-JP", "en-US"]
request.usesLanguageCorrection = true
// 信頼度 >= 0.40 を採用、0.25-0.39 はフォールバック
```

### Burst OCR

1回のシグナル取得で複数フレームをキャプチャして安定性を上げる仕組み。
最長テキストのものを採用。遅延・文字数は `details` に記録される。

---

## 2. Signal Collection

### Structural Signal

AX API で LINE チャットリストの行数変化を検出。

- 前回スナップショットより行数が増加 → score=70（高信頼）
- 減少 → score=20
- 変化なし → score=10

テキストは空で返す（Pixel Signal から取得）。

### Pixel Signal (`collectPixelSignal`)

**Image Hash**
```
画像をダウンサンプルして 64bit ハッシュ → 前回 hash と比較
hash 変化なし → return nil（早期脱出）
```

**テキスト変化判定**
```
textChanged = (currentOCRText != lastOCRText)
  true  → score = 62
  false → score = 35 (hash は変わったが内容は同じ)
```

`textChanged=false` のとき `text_unchanged prev=[...] curr=[...]` としてデバッグログに記録。

---

## 3. Text Cursor Truncation

**目的**: 直前に emit したテキストより前を切り落とし、新しい末尾だけを Pixel Signal に渡す。

**実装** (`applyCursorTruncation`):

```
前回 emit 時のテキスト末尾 4行 をカーソルとして保持
  ↓
次回 poll の OCR テキストでカーソル行を fuzzy マッチで探す
  ↓
見つかった最後の位置より後ろだけを delta 候補として返す
```

**カーソル結果**:

| 状況 | `pixel_cursor_status` | 挙動 |
|------|-----------------------|------|
| カーソル未設定 / conversation 変更 | `not_applicable` | 全テキストを候補として返す |
| カーソル行が見つかった | `applied` | カーソル以後のみ返す |
| カーソル行が見つからない | `not_found` | **空文字を返す（fail-neutral）** |

`cursor_not_found` で全文を再処理しないのが今回の重要点。これでスクロールや anchor loss 時に古い画面全文を再 emit しなくなる。

---

## 4. extractDeltaText

```
previousLines (Set) と currentLines の差分を取る
  → delta が空 → OCR の行分割ドリフト対策で currentLines 全体を返す
  → delta あり → 差分行のみ返す
```

`applyCursorTruncation` が `not_found` を返した場合は current が空なので、ここでも fail-open しない。

---

## 5. Fusion Engine

各シグナルのスコアを合算して閾値と比較する。

```
default threshold = 60

pixel_diff (textChanged=true)  = 62 → 単独で通過
pixel_diff (textChanged=false) = 35
structural_signal (行数増加)   = 70 → 単独で通過

合計スコア >= 60 → shouldEmit = true
```

echo チェック（RecentSendTracker）も fusion 前に走る。echo と判定されると `echo_message` イベントになる。

---

## 6. Swift 側 Dedup (`shouldSuppressDuplicateInbound`)

Fusion 通過後の重複除外。現行ポリシーは **fresh-evidence first**。

### 6-1. 判定順序

```
1. fingerprint_window hit               -> suppress
2. primary fresh evidence exists        -> emit
3. cursor_not_found and no fresh signal -> suppress (fail-neutral)
4. content_memory hit                   -> suppress (assist only)
5. otherwise                            -> emit
```

### 6-2. Fingerprint Window

```
fingerprint = "会話名|正規化テキスト"
同一 fingerprint が short window 内にあれば suppress
```

`windowSeconds` = V2 有効時は `inboundDedupWindowSecondsV2`、無効時は 20秒。
短時間の二重配送だけを止める一次防波堤。

### 6-3. Primary Fresh Evidence

以下のどれかが立てば、`content_memory` より優先して emit する。

- `incoming_rows > 0`
- `pixel_post_cursor_novel_lines > 0`
- `ax_bottom_changed=1 && newest_slice_used=1 && pixel_text_changed=1`
- `pixel_cursor_status=not_applicable && pixel_text_changed=1`

これで「13分後の同文面再送」のようなケースを stale memory だけで落とさない。

### 6-4. Content Memory Assist

テキストを行単位に分解し、conversation ごとに短命メモリへ積む。

```
normalizedLines = テキストを句読点で追加分割 → 2文字以上を対象
TTL = 90秒
maxSeenLinesPerConversation = 240
```

**使い方**:
- primary evidence がないときだけ suppress 判定に参加する
- 同じ行を再受理した場合は `seenAt` を更新する
- TTL を超えた行は判定前に prune する

### 6-5. Fuzzy Dedup (`linesLikelyEquivalent`)

行メモリ検索時に厳密一致ではなく近似一致を使う:

```
1. 完全一致 → true
2. 短い方が長い方に含まれ、被覆率 >= 84% → true  (min length 8文字)
3. Trigram 類似度 >= 88% → true  (min length 8文字)
```

**Trigram 類似度**:
```
F1-like: 2 * |common_trigrams| / (|lhs_trigrams| + |rhs_trigrams|)
```

ヒット時: `fuzzy_dedup_hit query=[...] matched=[...]` としてデバッグログに記録。

### 6-6. Debug Reasons

`/v1/debug/line-dedup` の pipeline reason は次を返す:

- `suppressed_fingerprint_window`
- `accepted_primary_evidence`
- `suppressed_cursor_neutral`
- `suppressed_content_memory_assist`
- `accepted`

---

## 7. Gateway 側 Dedup (gateway.js)

ClawGate から gateway plugin へのイベントがさらに複数のフィルタを通過する。

### 7-1. Plugin Echo Guard (`isPluginEcho`)

```
ECHO_WINDOW_MS = 10分
recentSends: ClawGate が LINE に送信したテキストを保持

受信テキストが recentSends と類似 → echo として drop
```

類似判定は行ベースの逐次比較（60% マッチで判定）。
miss 時: `[echo_guard_miss] text_head="..." active_sends=N last_send_age_ms=M` を記録。

### 7-2. Short Dedup

短いテキスト（特定の長さ以下）を対象とした別ウィンドウの dedup。

### 7-3. Common Ingress Dedup

```
COMMON_INGRESS_DEDUP_WINDOW_MS = 20秒  (旧: 45秒)
```

全チャンネル横断で同一テキストの重複を 20秒以内でブロック。
Watcher 再起動直後の「同一メッセージの二重取得」を gateway 側でも防ぐ。

### 7-4. Burst Coalesce (`enqueueLineBurstEvent`)

```
1.5秒バッファ: 1.5秒以内に届いた複数イベントをまとめて1件にする
→ 非常に速い連打やネットワーク由来の重複に対応
```

---

## 8. Baseline Race と Fix

**問題**: Watcher 起動直後、LINE 画面に既存メッセージが表示中の場合:

```
最初の poll:
  baseline.text = "受信メッセージ" → lastOCRText に保存  ← 旧実装の問題
  return nil

次の poll:
  OCR が同じテキストを返す
  → textChanged = false → score = 35
  → fusion score < 60 → drop_stage=fusion
```

**Fix**: `lastOCRText = ""` で初期化（baseline 取得時は OCR 結果を破棄）。
次の poll で必ず `textChanged = true` → score = 62 → 通過。

---

## 9. Autonomous Stall 検知 (BridgeCore.swift)

AI タスク完了後に LINE 通知が届かない場合の検知ロジック。

```
autonomousStallThresholdSeconds = 120秒

completion (tmux.completion) から 120秒以内に line_send_ok が来ない
  かつ send_failed の error_code == "session_typing_busy"
    → suppressionReason = "stalled_typing_busy"
    → reviewDone = false  (通知は止めない)
  それ以外
    → suppressionReason = "stalled_no_line_send"
    → reviewDone = true   (通知停止)
```

**line_send_ok の相関**:
1. trace_id 厳密マッチを優先
2. trace_id 不一致でも completion から 5分以内の line_send_ok があれば相関成立（proximity fallback）

**typing_busy streak**:
```
送信成功 → typingBusyStreakCount = 0
session_typing_busy エラー → typingBusyStreakCount += 1
  → "BridgeCore: typing_busy streak=N" をデバッグログに記録
```

---

## デバッグの手引き

### メッセージが届かないとき

1. `/tmp/clawgate-ocr-debug/latest-pipeline.json` を確認
   - `drop_stage` が `fusion` → score 不足。`pixel_text_changed=0` なら Baseline Race
   - `drop_stage` が `dedup` → line memory dedup ヒット

2. gateway.log で `ingress_accepted(dedup_reason=none)` → `handleInboundMessage` に進んでいるか確認

3. `cursor_truncation discarded=N kept=M` がログに出れば cursor が機能している

### Chi の返答が時間を置いて再送されるとき

- `echo_guard_miss` が出ていれば plugin echo guard をすり抜けている
  → `ECHO_WINDOW_MS` の調整、または `linesLikelyEquivalent` の閾値調整を検討
- `cursor_not_found` が出ていれば cursor が消えている（スクロールや conversation 変更）

### 関連定数まとめ

| 定数 | 値 | 場所 |
|------|----|------|
| `autonomousStallThresholdSeconds` | 120s | BridgeCore.swift L20 |
| `inboundLineMemoryWindowSeconds` | 75s | LINEInboundWatcher.swift L49 |
| `inboundDedupWindowSeconds` | 20s | LINEInboundWatcher.swift L50 |
| `textCursorLineCount` | 4行 | LINEInboundWatcher.swift |
| `ECHO_WINDOW_MS` | 600,000ms (10分) | gateway.js L712 |
| `COMMON_INGRESS_DEDUP_WINDOW_MS` | 20,000ms | gateway.js L836 |
| `minAcceptedCutRatioFromTop` | 0.84 | VisionOCR.swift L128 |
| fusion threshold | 60 | LineDetectionFusionEngine |
