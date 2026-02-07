# Pixel Diff Detection for LINEInboundWatcher

## 指示
LINE (Qt macOS) が AX ツリーを更新せずピクセルだけ描画更新する問題に対し、
ピクセルハッシュ比較による受信メッセージ即時検出を実装。

## 作業内容

### 変更ファイル
- `ClawGate/Adapters/LINE/LINEInboundWatcher.swift`
  - L17-20: pixel-change detection state (lastImageHash, lastOCRText, baselineCaptured)
  - L149-191: doPoll() 末尾にピクセル変化検出ロジック追加
  - L195-213: computeImageHash() — 32x32 ダウンサンプル + FNV-1a ハッシュ
- `ClawGate/Core/Config/AppConfig.swift:9`
  - pollIntervalSeconds: 10 -> 2
- `docs/testing.md` — pixel_diff 検出の説明追加

### 検出フロー
1. 毎ポーリング(2s)で LINE ウインドウの CGImage をキャプチャ
2. 32x32 にダウンサンプル → FNV-1a ハッシュ比較（~5ms）
3. ハッシュ変化 → Vision OCR でテキスト抽出（~300ms）
4. OCR テキストが前回と異なれば `inbound_message` (source: "pixel_diff") を emit
5. echo suppression は既存の RecentSendTracker を利用

### 動作確認
- Build: 成功（warning 0）
- Deploy + re-sign: 成功（ClawGate Dev 証明書）
- Doctor: 6/6 PASS（AX + Screen Recording 権限 OK）
- テスト: `pixel test` 送信 → `source: "pixel_diff"` イベント確認
  - OCR テキストにメッセージ内容が含まれている

## 課題
- 会話遷移時（sidebar → chat view）に大量のピクセル変化イベントが発生する
  → ただしこれは正しい動作（画面全体が変わるため）
- OCR は全ウインドウを対象にするため、新着メッセージだけでなく全テキストが含まれる
  → テキスト差分で新着部分を抽出する改善が将来的に可能
