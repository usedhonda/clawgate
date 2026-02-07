# LINE(Qt5) 合成Enter未達の根本原因分析（006）

作成日: 2026-02-06  
関連: `docs/log/codex/004-line-enter-send-analysis.md`, `docs/log/codex/005-line-enter-followup-analysis.md`

## 0. 前提（今回の確定情報）
- `AX setValue` で本文注入は成功。
- 物理キーボード Enter は送信成功。
- `osascript key code 36`, `CGEvent(.cgSessionEventTap/.cghidEventTap)`, `NSAppleScript` は失敗。
- 合成マウスクリックはLINEに届く（効く）。
- Qt `qnsview.mm` の `keyDown:` に「syntheticイベント明示フィルタ」は見当たらない。
- クリック後にEnterを送っても失敗。

## 1. 質問1への回答
### Qt5がCGEventキーボードを受け取れない根本原因候補
最有力は「Qtが拒否」ではなく、**macOS入力パイプライン上でキーボード合成イベントが最終的な編集コンポーネントへ到達していない**こと。

優先度順に見ると次の3層。
1. 配信層の差
- マウスは届くがキーだけ届かない場合、WindowServer/Session/TSM(テキスト入力管理)経路でキーが落ちる可能性。
- キーボードはマウスより入力管理の関与が大きい。

2. テキスト入力層（IME/TSM/NSTextInputClient相当）
- Qtテキスト入力は `keyDown` 直通だけでなく、IME合成・テキストサービス経路の影響を受ける。
- 合成CGEventが「通常のハードウェア由来入力」と同等に扱われず、確定/送信トリガへ進まない可能性。

3. フォーカス層
- クリック成功後でも、Qt内部で「送信判定を持つ実編集オブジェクト」へキーが来ていない可能性。
- AXフォーカスや見た目フォーカスと、実際のキーイベント受理ターゲットが一致しないケース。

補足:
- `qnsview.mm` に明示的filterがなくても、より下位（AppKit/TSM/WindowServer）で差が生じれば同現象は起こる。

## 2. 質問2への回答
### `nil source + .cghidEventTap` は有効か？
- **試す価値はあるが、本命ではない**。
- 理由:
  - 既にtap差（`cgSession`/`cghid`）を試して不成功。
  - sourceを`nil`にするとメタデータが変わり、通る環境はある。
  - ただし根因がTSM/入力コンテキスト側なら source差だけでは改善しない可能性が高い。

実務判断:
- 低コストの追加分岐としては妥当。
- ただし「これで直る前提」で戦略を組むのは危険。

## 3. 質問3への回答
### CGEvent以外の代替手段
公開APIで現実的な順は次。
1. `AXUIElementPostKeyboardEvent`（pidターゲット）
- グローバル注入より届くケースがある。

2. 送信をキー依存から外すUI操作（もし将来LINE UIに送信ボタンが露出する場合）
- 今はAX上ボタン無しなので現状難しい。

3. AppleScript GUI Scripting（System Events）
- 既に失敗済み。最終fallback以上にはなりにくい。

4. Clipboard + Paste + (別経路Enter)
- 入力には有効でも送信トリガ問題は残る。

`IOHIDPostEvent` について:
- 原則非推奨。
- 非公開/将来互換性/配布審査/保守リスクが高い。
- 公開API中心の設計方針（本プロジェクト方針）と衝突。

## 4. 質問4への回答
### 物理キーボードとCGEventの違い（実務上重要な点）
厳密には内部実装差があるが、現象に効く差は次。

1. 生成起点
- 物理: HIDデバイス由来（IOKit -> WindowServer）
- CGEvent: プロセス生成の合成イベント

2. 信頼性/属性
- 物理イベントにはデバイス由来属性・時系列・入力サービス連携が自然に揃う。
- 合成イベントは一部属性が異なり、入力管理やアプリ側で同等扱いされない場合がある。

3. テキスト入力サービス連携
- 物理入力はIME/TSMフローと整合しやすい。
- 合成入力は同経路に乗っても、最終的な確定・送信判定まで届かないケースがある。

4. セキュリティ/ポリシー影響
- macOSのバージョンやTCC状態、実行主体プロセスによって、合成キーだけ通りにくい状況がある。

## 5. 現時点の結論
- 現象は「Qtがsynthetic keyを明示拒否」より、**macOS入力経路差（特にキー系）**で説明する方が整合的。
- マウス成功・キー失敗という非対称は、source/tapだけでなくTSM/IME/first-responder連携の問題を示唆。
- `nil source + .cghid` は追加テスト価値ありだが、決定打と見なさない。

## 6. 次の調査提案（実装ではなく検証設計）
1. 同一条件で `AXUIElementPostKeyboardEvent` を比較対象に置く。
2. Enter種別を分離して評価（Return 36 / KeypadEnter 76 / Cmd+Enter）。
3. 送信直前に `kAXFocusedUIElementAttribute` と selectedTextRange相当を記録し、キー未達か判定未発火かを分離。
4. IME状態（英数直接入力 vs 日本語変換中）でA/B比較。

## 7. 追加で確認したい点
1. 失敗時、LINE内でショートカット（例: Cmd+L等）は合成キーで反応しますか？
2. 同じ合成Enterを、Qt以外のアプリ（メモ等）では成功しますか？
3. LINEで英数入力モード固定時と日本語入力時で差はありますか？
4. ClawGate実行バイナリ自体の Accessibility/Input Monitoring 状態はどうなっていますか？
