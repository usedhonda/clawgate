# LINE(Qt) Enter送信失敗 追加分析（005）

作成日: 2026-02-06  
前提レポート: `docs/log/codex/004-line-enter-send-analysis.md`

## 0. 今回の追加事実（ユーザー共有結果）
1. 物理Enterは送信成功（`AX setValue` 後でも可）
2. `osascript`（LINE activate + System Events key code 36）は失敗
3. Terminal の Accessibility 権限は ON
4. `CGEvent` は `.cghidEventTap` / `.cgSessionEventTap` とも失敗
5. AX上、入力欄 `AXTextArea` の action は `AXRaise` のみ（`AXPress`/`AXConfirm` なし）

この5点から、`text認識` ではなく `合成イベントの到達先（first responder）` がボトルネック、という推論は妥当。

## 1. 質問への回答

### 1) `CGEvent` マウスクリックは Qt製アプリで有効か？
- 有効なケースは多い。
- 理由: Qtでも最終的にマウスダウン/アップでフォーカス遷移を処理するため、クリックで first responder を明示的に作れることがある。
- ただし「常に有効」ではない。ウィンドウ座標ズレ、スクロール、DPI/Retina変換ミスで外すと失敗する。

### 2) マウスイベントもフィルタされるリスクはあるか？
- ある。
- ただし今回の症状では、キーボード単体よりマウスクリックのほうが通る可能性は高い。
- アプリ側が「合成イベント排除」を実装している場合、キー/マウス両方失敗し得る。

### 3) 他に見落とし得るアプローチは？
優先度順に以下。
1. `AXUIElementPostKeyboardEvent`（pid指定）を先に比較
2. クリックでフォーカス確立後にEnter（座標クリック戦略）
3. `Cmd+Enter` / `KeypadEnter(76)` の分岐
4. 「setValue後に末尾1文字を実入力してからEnter」のハイブリッド
5. 最終fallbackとしてAppleScript GUI操作（座標クリック + key code）

`IOHIDPostEvent` など低レベルAPIは、
- 非公開/将来互換性リスク
- 権限・配布・保守コスト増
- 問題の本質（focus不成立）を直接解かない可能性
のため、現時点では推奨しない。

### 4) osascriptでもダメな本当の原因は？
最有力は次の2つ。
- `activate` は「アプリ前面化」であり「テキストエリアをfirst responder化」まで保証しない。
- `System Events key code` は frontmost app 宛てのキー送信で、Qt内部でフォーカス対象が入力欄でなければ送信トリガーに到達しない。

補足: Terminalの権限ONでも、System Events経路の成否には「対象アプリ内フォーカス状態」が支配的。

## 2. 方向性評価（クリック→Enter案）
結論: **妥当で、次の第一候補にしてよい**。

根拠:
- 物理Enterは成功しているため、入力欄が実フォーカスなら送信できる。
- 現在は「実フォーカス確立」の証拠がない。
- クリックは Qt の通常フォーカス遷移に寄せられる。

想定リスク:
- 座標依存で壊れやすい（ウィンドウサイズ、UI変更、多画面）
- クリックで意図せず別要素に当たる
- 合成マウスも拒否される環境では効果なし

## 3. 実装前に決めるべき検証設計（提案）

### 3.1 検証シナリオ最小セット
1. `setValue` のみ + Enter（現行ベースライン）
2. `setValue` + クリック + Enter
3. `setValue` + `AXUIElementPostKeyboardEvent` Enter
4. `setValue` + クリック + `AXUIElementPostKeyboardEvent` Enter

### 3.2 成功判定
- 入力欄が空になったか
- 末尾メッセージに本文が現れたか
- 失敗時に記録: frontmost bundle id / focused role / クリック座標 / キー送信方式

### 3.3 フォーカス確認の観測項目
- `kAXFocusedUIElementAttribute` が message input を指しているか
- クリック前後で focused element が変化したか
- 可能なら caret存在をAX属性（selectedTextRange等）で確認

## 4. 現時点の推奨戦略順
1. 送信キー設定差分を確定（EnterかCmd+Enterか）
2. `AXUIElementPostKeyboardEvent` 比較
3. クリックで first responder を確立してから Enter
4. それでも不可ならハイブリッド入力（末尾1文字実入力）
5. AppleScriptは最終fallback扱い

## 5. 追加で確認したい点
1. `LINE activate` 後、手動で入力欄を一度クリックしてから `osascript key code 36` を流すと送信されますか？
2. LINE設定の送信キーは Enter 固定ですか？（Cmd+Enter ではないか）
3. 失敗時の `kAXFocusedUIElementAttribute` は本当に message input ですか？
4. 日本語IMEの変換確定状態（未確定文字列あり）で再現差はありますか？
