# LINE(Qt) Enter送信失敗の調査メモ

作成日: 2026-02-06
対象: `ClawGate/Automation/AX/AXActions.swift:18`, `ClawGate/Adapters/LINE/LINEAdapter.swift:121`, `ClawGate/Adapters/LINE/LINEAdapter.swift:189`

## 1. 現状整理
- `kAXValueAttribute` への `AXUIElementSetAttributeValue` で入力欄に本文は入る。
- 送信は `CGEvent` の Return (`virtualKey: 36`) を `.cghidEventTap` へ `post` している。
- ただし LINE 側で送信トリガーされない。

既存実装を見る限り、Enter送信時は以下の流れ。
1. `app.activate(...)`
2. `AXFocused = true` 試行
3. `sleep(0.1)`
4. `CGEvent keyDown/keyUp(36)` を `.cghidEventTap` に送信

## 2. 主要仮説（優先度順）

### H1: フォーカス成立の種類が不足（最有力）
- `AXFocused` が成功しても、Qt 側で「実キーボード入力を受ける first responder」になっていない可能性が高い。
- AXで値を直接書き換える操作は、通常のキー入力イベント経路（KeyDown/KeyUp）を通らないため、Qt側の内部状態（編集状態、送信可能判定）とズレることがある。

### H2: イベント注入先のtapが不適合
- `.cghidEventTap` は低レベル注入。アプリによっては `.cgSessionEventTap` / `.cgAnnotatedSessionEventTap` の方が安定するケースがある。
- 特に「前面アプリのキーボードイベントとして届くか」が重要で、tap先差異が効く可能性がある。

### H3: LINE設定と送信キーの不一致
- LINE設定で「Enterで送信」がOFFだと、必要キーは `Cmd+Enter` になる。
- 実装は `Return(36)` 固定で、`Cmd+Return` や `KeypadEnter(76)` を試していない。

### H4: アクティベーション直後のタイミング不足
- `activate` 後 0.1s は Qt ウィンドウ再フォーカス完了として短い場合がある。
- AXフォーカス成功と実際のイベント受理可能状態にラグがある。

### H5: AX setValue後にQtが「入力イベント由来」と認識しない
- プログラム書き換え後、Qt側で送信可否を決める内部フック（textChanged経路など）が通らない実装だと Enter が無視され得る。

## 3. Qt系アプリで実際に起きやすい罠
- AXで文字列を直接注入すると、アプリ固有の「キー入力前提ロジック」が発火しない。
- `AXFocused=true` は「AX属性としてのfocused」であり、必ずしも AppKit/Qt のキーボードフォーカス保証ではない。
- 合成キーイベントは「どのセッションtapへ投げるか」「前面化が完全に終わっているか」に依存しやすい。
- Enter種別差（Return vs Keypad Enter）や修飾キー差（Cmd+Enter）が無視できない。

## 4. 切り分け提案（実装なし、検証観点のみ）

### 4.1 最小マトリクス検証
送信トリガー候補を4軸で比較し、どこで通るかをまず特定する。
- 入力方式: `setValue` / 疑似タイピング
- キー種別: `Return(36)` / `KeypadEnter(76)` / `Cmd+Return`
- tap先: `.cghidEventTap` / `.cgSessionEventTap` / `.cgAnnotatedSessionEventTap`
- 送信API: `CGEventPost` / `AXUIElementPostKeyboardEvent`

### 4.2 成否判定の観測点
- 送信後に入力欄が空になるか。
- 最新メッセージに本文が現れるか。
- 失敗時に「前面アプリ bundle id」「AXFocused要素 role/subrole/value」「送信キー種別」をStepLogに残す。

### 4.3 まず疑うべき順序
1. LINEアプリ設定の送信キー（Enter送信ON/OFF）確認。
2. 前面化完了の確認（frontmost appがLINEか、入力欄にキャレットが見えるか）。
3. `.cgSessionEventTap` と `AXUIElementPostKeyboardEvent` の比較。
4. `setValue`後1文字だけ実キーストロークを入れる方式との差比較。

## 5. 代替アプローチ候補

### A. `AXUIElementPostKeyboardEvent(pid指定)` を第一fallbackにする
- 利点: ターゲットプロセスに紐づくため、単純なグローバルCGEventより届きやすいケースがある。
- 欠点: 古いAPIで挙動差があるため、実機検証は必要。

### B. 送信操作を「キー送信前提」に寄せる
- 本文全量を `setValue` でなく、少なくとも最後のトリガー部分だけ実キーストローク経由にする。
- Qtのイベントループ側に自然に載せることを狙う。

### C. AppleScript `System Events` の keystroke/key code を最終fallbackにする
- 利点: 上位レイヤ経由で成功する環境がある。
- 欠点: Automation許可が増える、遅い、失敗要因が増える。

### D. 送信ボタン探索を再評価
- 現状「ボタンなし想定」だが、LINEバージョン差でAXPress可能ボタンが出る可能性はゼロではない。
- AXDumpで action一覧（`AXPress` 可否）を再確認するとよい。

## 6. 推奨方針（実装時の意思決定）
- 送信戦略は単一手段に固定しない。
- 優先順は「AXPress -> AXUIElementPostKeyboardEvent -> CGEvent(複数tap/キー種別) -> AppleScript」。
- 失敗時は「どの戦略をどの順で試し、どこで落ちたか」を必ず返す。

## 7. 追加で欲しい情報（回答いただければ精度を上げられます）
1. LINE側の「Enterで送信」設定はONですか？（OFFなら `Cmd+Enter` が必要）
2. 失敗時、LINE入力欄にキャレットは見えていますか？
3. 同じタイミングで手打ちEnterは送信できますか？
4. `CGEvent` の tap先を `.cgSessionEventTap` に変えた試験は未実施ですか？
5. `AXUIElementPostKeyboardEvent` は未試験ですか？（もし試験済みなら結果）
