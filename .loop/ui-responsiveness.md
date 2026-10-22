# LOOP: UI応答性改善を1課題ずつ受入まで進める

## 現在の再開条件 / 2026-10-22

本人の通常メッセージによる継続scopeで作業する。新しいGoalやagentは作らない。
最新到達点は`ui-responsiveness-state.md`冒頭を正本とし、以下の旧backend状態、lock、未反映の記述は各履歴時点のもの。
既存sourceの保存と議事録修正時の反映は確認済み。残るS4/S5性能計測とS7最終レビューを、既に済んだ実装・green検査から分離する。

## GOAL / Project Profile

計画A〜Dの限定された操作経路で、既存機能を維持しながら古い表示の逆流・重複処理・main threadの重い準備を解消し、ソース・focused検査・実操作の証拠を分けて受入する。

- Kind: closed。監視や全体refactorではなく、後述の有限backlogを処理する。
- Runtime: 既存Codex Goal継続を希望するが、今回確認したbackendはblockedで、提供toolにresume/active操作がない。新規Goalやrunnerで代替しない。実行可能な代案は、継続ownerとの同時書込みがないことを確認した通常メッセージでの1 iteration。「1課題ずつ」は変更を混ぜない単位であり、Goalが正規に再開された場合のturn終了を承認待ちにしない。生成では何も起動しない。
- 成熟したSwiftPM macOSアプリ。`Package.swift`の`UnitTests`と既存focused testsを利用する。UI応答性は単体テストだけでは証明できない。
- 初版作成時点のHEADは`37d7b89`。これは履歴であり現在値ではない。最新確認HEADは`a5dc19d`、B/A/C2はそれぞれ`082a936`/`041c975`/`a5dc19d`へ保存済み。C1と既存議事録WIPは残り、live受入は未完了。
- 既存loopのCI全緑・一般負債返済・WIP全体統合とは目的が異なる。他loopの未完了項目・全緑条件・完了ledgerを取り込まない。
- 元計画は`.local/performance-improvement-plan-20261019.md`。このファイルにも必要なscopeを収録し、private計画がなくても勝手に対象を増やさない。

## 再開用タスクプラン / 2026-10-20

今回の依頼は、現在の障害・進行中の残件を整理し、既存の相談先と相談したうえで
Codexで再開できる契約を作ること。生成だけでは実装・Goal・automationを起動しない。
本ファイルと既存stateを更新し、重複loopやrunnerは作らない。

### 現状の分類

- A/B/C1/C2: 候補実装とfocused検査の履歴あり。稼働アプリへの反映・live受入は未実施。
- D: 本体未変更。隔離fixtureのtimer latenessは入力/scroll→表示時刻ではなく、採否未決。
- レビュー: 初回ローカルレビュー済み。独立レビュー・相談の返答は未受領。
- 運用境界: 録音のcapturing/live/runningは過去の観測であり現在値ではない。録音中断は禁止。
  旧lockは本人の修復指示で除去しC2を保存済み。今回の生成時にもlock存在を読取確認したが、同一性・holder・作成主体は未調査。旧lockの修復成功や承認を、このlockの無条件削除許可に置換しない。
- 相談経路: 本人binding不一致で送信拒否。実送信を試みたことと、相談成立を区別する。
- 別プロジェクトからのLINE/Hub照会: 公開metadataの限定観測は実施したが返信未達。
  Hub選択・capabilityのboolと現laneは未観測。応答性改善の実装scopeには取り込まない。

最新の時刻・照会の正確なID・送信結果はignoredの
`docs/log/codex/302-ui-responsiveness-loop-refresh.md`と
`docs/log/codex/309-block-repair-C2-save.md`、今回の訂正は
`docs/log/codex/310-loop-contract-repair.md`に置く。
古いstatus値を現在値として使わず、判断が必要な時だけ同じ安全なsurfaceを読む。

### 有限backlog / 依存関係

| 順 | タスク | 完了証拠 / 次へ進む条件 |
|---|---|---|
| K0 | 既存相談先への相談経路を確認し、優先順・抜け・受入条件の助言を受ける | 現conversationの正規binding、送信結果、正確な受信返信ID、助言の採用/一部採用/不採用理由。受付や自己レビューだけでは相談完了にしない |
| K1 | A/B/C候補と既存証拠を照合 | 対象内容revisionとテストの対応。既に通った同一証拠を再実行せず、実際の未達だけ残す |
| K2 | Dの観測器と測定条件を確定 | 接続可能なnative観測器、内容なし操作ID・入力/表示時刻・標本数・binary識別子。空captureやtimer遅延の代用は禁止 |
| K3 | Dの採否を決め、必要な変更のみ行う | 同一workloadの測定根拠。変更なら意味保持テストと差分レビュー。観測不能はunverifiedのまま |
| K4 | A/B/C/Dのnative受入と安全なlocal反映 | 録音保護条件を満たすcanonical反映、S1-S5の直接証拠。反映前baselineを安全に取れなければ不足として残す |
| K5 | 最終レビュー・機密検査・対象commit | S6、review findingの処置、正規に解消されたGit lock、対象差分だけのcommit。pushしない |
| K6 | 残件と判断を一対一で報告 | S1-S7が証拠つきで全達成した場合だけFINAL。未達・未反映・未相談を隠さない |

K0の通信障害があってもK1など安全で独立した作業は進められる。
ただし「相談したうえで確定した計画」とは呼ばない。
新規agent作成・別identity借用・受信文の他peerへの転送・本人への伝言依頼は禁止。
本人binding拒否を同じ条件で連続試行せず、正規の接続修復手順と現在本人の一致を
確認できた場合だけ元submissionを照会・再試行する。新しいIDで重複送信しない。
別プロジェクトへの旧返信も元IDと送信結果を保持し、無関係なscopeの実装やqueue操作へ広げない。

### レビュー工程

- 最初は`docs/log/codex/301-ui-responsiveness-plan-review.md`のローカルレビューを引き継ぐ。
  相談先の助言を受信したら、具体的な入力→誤結果の根拠とscopeを照合する。
- makerとcheckerを分離する: 既存の独立assertion、barrier競合検査、native操作計測を
  判定に使う。実装担当の「良さそう」や返信の沈黙は合格証拠にしない。
- main反映時のrecord読取・JSON metadata列挙は正当性のfenceとして残っている。
  S5の計測対象にし、遅いという根拠なしにfenceを削除しない。
- 最終安定差分につき統合レビュー1回。具体的findingを直した場合だけその部分を再確認。
  自動spawn・未変更の反復review・親による同一suiteの重複実行は禁止。

## AUTHORIZATION / 非対象

今回の生成は契約修正のみであり、プロジェクト作業を開始しない。ただしstateに保存された既存のA〜D実装・最小検証・安全な反映・対象commitの本人承認は消去しない。再開はそのscopeと継続条件を引き継ぎ、同じ承認を取り直さない。認証の相談指示は存在するが、他列のsource変更権限や別identity利用へ拡張しない。

起動文がA〜Dを承認していれば、その承認は同一Goalの後続turn・context復元へ引き継ぐ。毎回「続けますか」「次はBでよいか」を聞かない。Goalがactiveで未達なら実際の次の作業を行う。`ITERATING`という文字や長い契約だけで自動継続が設定されたと主張しない。

- 現在会話で行う。新規agent・worker・別チャット委任や新しいレビューcampaignを自動開始しない。
- 対象はA/B/C1/C2/Dのみ。Dの改修は寄与を計測できた場合だけ。初期化順・全体分割・一般的な負債返済へ拡張しない。
- LINE / Gateway / Hub / plugin / 認証・接続 / 音声captureは変更しない。remote hostの再起動、実入力replay、実生成や通知を試験のために発火することも対象外。
- 機能停止、timer間隔延長、event破棄、録音中断で速く見せない。本文・認証情報・個人識別子を公開ファイルや外部reviewへ出さない。
- 不明な`.git/index.lock`を削除・移動・迂回しない。その影響はGit書込だけへ限定し、安全な調査や独立作業まで禁止しない。
- scope内commitは既存承認と適用Git規則に従う。push/releaseは含まない。既存WIP全体のsavepointを勝手に作らない。Git lockがあればその書込みだけ保留し、契約生成や安全な読取を全体禁止にしない。

## BACKLOG / 順序と具体的な反例

### A: 日常ログの表示世代・coalesce・不変入力の再利用

対象: `ClawGate/UI/Pet/AmbientLogPetView.swift`。必要な最小範囲で`ClawGate/Core/Ambient/AmbientStorage.swift`と既存AmbientLog tests。

- 根拠: `load`はserial queueへ都度追加され、todayのsegments/scene作成後にfingerprintを比較する。表示反映のguardは日付だけで、旧`resolved.selection`を書き戻せる。query準備も同じqueueを利用する。
- 入力→誤結果: 同日S1のloadを実行中にS2へ選択し、旧S1が後着すると選択を戻せる。A日→B日→A日、font変更、stop後も表示世代の照合が必要。
- 最小案: 表示専用generationとimmutable入力を固定し、実行中1件＋最新pending1件、協調cancel、最新結果のみ適用。同一source revisionではraw抽出/scene構築を再利用する。
- 維持: 既存queryGeneration/actionEpoch、選択範囲・全文入力・timezone・cancel/所有者保護。fontだけの変更でsemantic queryを不必要に無効化しない。下位decode cacheは既に存在し、毎回全ファイルdecodeとは主張しない。

### B: メニューのイベント表示projectionをoff-main化

対象: `ClawGate/UI/MenuBarApp.swift`、必要な最小範囲の`ClawGate/main.swift`と`ClawGate/Core/Logging/OpsLogStore.swift`、関連tests。

- 根拠: EventBus通知と2秒timerが`refreshStatsAndTimeline`へ入り、mainでfile tail読取・decode・要約・publishする。既に上限30件・tail予算36,000bytesであり、無制限ログ読取ではない。
- 入力→誤結果: burstと未変更tickで同じtailを繰り返し処理し、mainの仕事を積む。
- 最小案: 専用serialized loaderの表示snapshotをmainへ適用。1実行＋1最新pending、同一revision/同一内容の再整形・publishを抑える。共有decoderを無制御な並列queueへ移さない。
- 維持: 生eventの処理・ログ書込・配信・通知、最新30件の順序・要約・表示色・空表示・日付切替。間引くのは表示用の重複仕事だけ。

### C1: 議事録の生成操作に残る同期準備

対象: `ClawGate/UI/Pet/PetModel.swift`の`regenerateMinutes` / `requestMinutes` / instance `minutesEnvelope`、必要な最小のMeeting UIと関連tests。

- 根拠: UI操作の同期経路にsource読取・fusion・envelope/fingerprint・job読取保存が残る。既存表示snapshotの修正と別経路。
- 入力→誤結果: 長い会議で再生成を押すと、準備中表示より前に重い仕事をUI呼出し元で実行し得る。
- 最小案: mainで受付・準備中状態・所有権を確保し、immutable入力を専用workerで準備。request世代/source revision/job ownerを反映時に再照合し、既存admissionへ一度だけ渡す。

### C2: 議事録の自動候補巡回

対象: `PetModel.requestMissingMinutes`とそのsource provider境界、必要な最小の関連tests。

- 根拠: 起動時と300秒timerから全meeting・該当transcriptの準備へ同期到達する。`MeetingStore.all`は列挙/load/sort、providerはbackfill/境界計算/segments走査へ進む。
- 入力→誤結果: 履歴が多い5分tickで、表示窓と無関係にmainの全件準備が生じ得る。
- 最小案: 専用workerで候補準備をcoalesceし、mainへ戻って最新state/ownerを再照合して既存queueへ渡す。まずoff-main化し、永続index等は新しい測定根拠なしに追加しない。
- C1/C2共通維持: frozen input、indexed owner、resume/retry ticket、手動要求優先、未完了検出、資料・会議境界・既存accepted成果。UI表示snapshotを生成jobの固定入力と混同しない。生成dispatchを追加・重複させない。

### D: チャット描画は計測してから採否

対象: `ClawGate/UI/Pet/PetBubbleView.swift`と`PetModel`のstream表示境界のみ。

- 根拠: delta単位の表示更新・scroll animation依頼とbody helperのMarkdown/日時加工は存在する。全履歴全行が毎deltaで再parseされることやlive stall寄与は未証明。
- まず長文stream相当の隔離fixtureで入力・上scroll・タブ切替を計測する。実会話やAI送信を計測のために生成しない。
- 寄与ありの場合のみtext revisionごとの表示変換再利用と表示/scroll依頼のcoalesceを検討。寄与なしなら測定証拠つき`not-selected`、観測不能なら`unverified`。両者を混同しない。
- 維持: 全delta、確定text・リンク・code・選択/コピー・追従とユーザー上scroll時の追従停止。

## SUCCESS CRITERIA / VERIFY対応表

| ID | 必須条件 | checker / 直接証拠 |
|---|---|---|
| S1 | Aで旧表示適用0、最大1実行＋1pending、不変sourceのraw/scene再加工0。query意味保持 | 隔離fixtureのbarrierで同日S1→S2、A→B→A、font/stopを再現するassertionと既存AmbientLog検査、内容なしcounter |
| S2 | Bでmainのfile read/decode/要約0、不変tickの整形/publish0、queue有界、表示意味保持 | burst/未変更fixtureのassertion、既存OpsLog要約検査、対象経路のmain-thread観測 |
| S3 | C1/C2で重い準備/全件巡回がmain外。連打・更新・owner交代で旧結果上書き0、dispatchは既存規則どおり最大1 | fake provider/barrierで状態変更を挟むfocused assertion、既存retry検査、main-thread観測。実dispatchはしない |
| S4 | Dの採否が測定で確定。採用時は不変行再parse0・animation蓄積0、text/操作意味保持 | 同条件のstream fixtureとnative UI操作窓。未計測をnot-selectedにしない |
| S5 | 対象UI入力→選択/準備中表示のp95<=100ms、max<=250ms、ロード中も操作可能 | 同条件の改修前後のnative操作時刻と表示反映時刻、件数・p95/max・binary識別子。AI完了時間やFPSに置換しない |
| S6 | 対象差分のみ、既存WIP/禁止範囲を保全し、必要なローカル反映と正常動作確認済み | 差分確認、intent-guard、buildが必要ならcanonical restart結果と対象操作。healthだけではS1〜S5を証明しない |
| S7 | 既存相談先との相談結果を反映し、要求されたレビューとfinding処置を記録 | 正規bindingからの実返信と助言判断、統合diffと独立checkerの証拠。送信拒否・受付だけ・自己評価だけでは未達 |

数値は計画から引き継ぐ暫定受入目標であり、達成済みの実績ではない。`FINAL`には本人が起動時に採用した条件の全証拠が必要。都合の悪い条件をloop自身が削除・緩和しない。

## STATE / BUDGET

- State: `.loop/ui-responsiveness-state.md`。毎回読む。承認・作業ID・入力revision・実装/検査/反映/実操作/commitの状態を別々に保持する。
- 実行sliceの最初のaction（baseline検査を含む）の前にattempt IDを予約し、累積消費を増やしてrunningとする。中断分は消費済みのまま、再開で実物と照合してsettleする。生成・既存結果の整理だけでは実装attemptを増やさない。
- 過去8件の消費履歴は保持する。本人の2026-10-21指示により、agent既定の8回/80分は内部の再計画checkpointとし、その到達だけで停止・追加承認要求をしない。前進や具体的な失敗に基づいて方法を変更する。本人が指定した予算/期限、platform強制上限、安全境界は別であり厳守する。重複Goalは作らない。
- turn数・進捗報告数はiterationに数えない。仮説の作業サイクルは10分以内で点検し、必要なら仮説を修正して続行する。実行時間・token費用は未測定で推計しない。
- 同一課題でno-progressが2 iterationsなら、その仮説を打ち切って最小反例へ絞るか別の安全な残件を進める。同じ失敗には仮説・入力・差分のいずれかの変化を必須とし、3回目の同一試行は禁止。これだけでGoal全体を完了・中断しない。上限で自動再起動や新loop作成をしない。
- 合格は必要な直接証拠1組で足りる。連続green回数やreview回数を増やすために反復しない。
- stateの証拠キーはHEADだけでなく対象ファイル内容の識別子、fixture/件数、環境、実行binaryを含む。既存dirty下のHEAD一致だけで検査を流用しない。

## t=0 / 最初のVERIFY

1. 本契約・state・適用AGENTSを読む。既存の本人承認・exact Goal・owner・取消・残予算を照合する。保存済み承認を空扱いにしない。生成は実行ではなく、新規の実装sliceを開始しない。
2. `git status --short --branch`、`git diff --check`、対象差分で既存WIPと今回範囲を区別。作成時の5パスはstate参照。古い行番号を信用せずsymbolから経路を確認する。
3. 読取だけで既存証拠とcheckerの有無を確認。既存全緑suiteをbaseline取り直しの名目で実行しない。受入が既に全て証明済みなら、無変更で`FINAL`としてよい。
4. 初回起動ならA、再開ならstateの未達とK0-K6から次の安全な最小課題を選ぶ。Aから実装をやり直さない。可能なら変更前に対象の誤結果・操作応答を1窓記録。UI観測基盤が使えなければharness不通として分離し、live合格にはしない。

## EACH ITERATION

通常メッセージで「1 iteration」と指定された場合は、下記1〜6を1回だけ実行し、stateを保存して制御を返す。この実行単位の指定は承認・S1-S7・累積上限を変更しない。Goal継続を自動設定/再開したとは扱わず、次のsliceを同じturnで開始しない。

1. 再anchor: GOAL / 非対象 / 受入表 / stateを再読し、未達で最優先の1課題を選ぶ。新しい独立不具合は候補記録だけにして対象を増やさない。
2. PLAN: 具体入力→誤結果→期待結果、最小変更、今回のcheckerと検査が変える判断を1行ずつ固定する。`intent-guard start`でscopeを記録。
3. EXECUTE: 既存WIPの意味を保って対象だけ最小変更。`Task {}`だけでoff-mainを主張せず、actor/queue隔離とimmutable入力、協調cancel、世代/owner/revision再照合を確認する。
4. VERIFY: 下記の安い順で必要なcheckのみ実行し、最初のredでその故障を切り分ける。未変更のgreenを別コマンドで再証明しない。
5. APPLY: build/反映の安全条件が満たせる場合のみcanonical手順で対象を反映。反映未実施を受入済みにしない。commit承認があれば対象差分だけ扱い、未知lockは保全する。
6. RECORD: stateへ新証拠・差分・判断・未達・active時間・次の一手を追記。1課題の成功を全体成功にしない。全受入達成時のみ`FINAL`。残件ありなら短い途中報告の後、そのまま次の安全な作業を実行する。turnを終える必要がある場合もstateを残し、Goalの継続を利用して承認済み残件へ戻る。実作業があるのに文章だけでturnを消費したり、継続を偽装する無意味なtool呼出しをしない。

## VERIFY / 安い順・証拠の使い分け

### 1. Scope / static

`git diff --check`を実行し、対象の統合diffを一度確認する。既存dirtyと今回差分を区別し、禁止パス変更・機能無効化・test弱化・個人情報混入がないことを検査。`intent-guard check --change '実施内容 => 目標との直結理由'`でscopeを確認する。

### 2. Deterministic checker

既存entry pointは以下。課題に関係するclassだけ選び、安定したsliceごとに一度実行する。全部を毎回走らせる一覧ではない。

```text
swift test --filter AmbientLogCacheAndTimerTests
swift test --filter AmbientLogModelThreadTranscriptTests
swift test --filter AmbientLogTravelTimeZoneTests
swift test --filter OpsLogSummarizerTests
swift test --filter MainPanelTimelineLoaderTests
swift test --filter MeetingMinutesPreparationTests
swift test --filter MeetingMinutesRetryTests
swift test --filter MeetingMinutesExplicitRetryTests
```

- 実在するsymbolと現在のテスト内容を開始時に確認する。既存検査で不足する具体反例にだけ、最小のbarrier/counter assertionを追加する。新テスト名は実際に追加してからstateへ記す。
- makerは実装担当、checkerは実装の返り値を正解として作らない独立assertion・既存tests・native計測。自己評価文やreviewの沈黙をcheckerにしない。
- 新しい並行処理の順序はsleep頼みでなく、隔離fixtureで旧仕事を止めて選択/ownerを変えてから再開する。外部reviewを本人が依頼した場合はそのscopeで現在差分を渡すが、自動spawnや未実施reviewの捏造はしない。
- failed testはその1件だけ、原因に対応した変更/仮説の後に再実行。full suiteは明示されたrelease/CI gate等で必要なcheckpointだけ一度。未変更green・親側重複suite・反復reviewをしない。

### 3. Build / local反映

明示的buildやtestのbuildを含め、repo規則が要求する反映を安全に完遂できるか先にrunbookを確認する。録音中断や禁止hostの再起動が必要なら、その操作は実行しない。新しい高インパクト判断だけ本人へ具体化し、安全な独立作業を続ける。

local-onlyの明示的buildが必要なcheckpointでは`swift build`後、`./scripts/restart-local-clawgate.sh`で反映・稼働を確認する。広いrestart scriptはこのscopeでは使わない。スクリプト失敗時にad-hoc署名・kill・代替配布をしない。build PASSだけで完了を宣言しない。

### 4. Native操作 / observation-validity

GUI操作前にprojectの観測手順を読み、現時点で利用できる方法を確認する。過去のnative pipe障害は今回も継続していると推測しない。

- A: 同日選択連打→日付A/B/A→font変更→3秒境界。B: event burst相当の隔離入力→未変更2秒tick。C1: 長い隔離会議の準備中操作と競合。C2: fake候補scan中のowner変更。D: 隔離stream中の入力・上scroll・タブ切替。
- 前後で入力件数・操作列・fixture・build条件を揃え、操作IDと受付/表示時刻を相関する。内容なしのduration、回数、queue上限、旧結果適用数、main-thread stackだけ保存する。
- 空capture・時刻不明・凍結した観測・違うbinary・不十分な操作数は性能PASSにしない。観測器故障とアプリのhangを別の状態として報告する。p95の算出方法と標本数も記録する。
- 画面captureやhealthだけではp95/FPSを証明しない。S5の測定方法が未成立なら先に観測設計を決め、`unverified`を維持する。

## STOP taxonomy / 出口

FINAL/ITERATING/BLOCKEDは報告markerでありnative状態変更ではない。現backendはblockedで、ここからactiveへ戻す提供toolはない。既存Goalの正規再開が確認できるまではGoal起動コマンドを代案として出さない。上限到達時は新規actionを停止しstateと未達を保存するが、completeへ偽装しない。既存stateから残予算のまま再開し、再開手段が不明なら未設定と報告する。

- `success`: S1〜S7の必須条件が証拠で達成。Dが非採用ならその測定根拠も必要。`FINAL`。
- `external-blocked`: 安全な独立残件を検討した後、録音保護・未知lock・正規通信binding・native観測の不足で有効な次手がない。stateへ未達と必要な条件変化を記録し、BLOCKEDと報告。反復poll・sleep・再送でturnを消費しない。platformのblocked更新は実際の反復閾値規則に従う。
- `checkpoint`: 1課題完了・途中報告・turn境界は停止理由ではない。stateから次の残件へ続行し、最初の監査を繰り返さない。
- `budget`: 本契約またはplatformの実上限に達した場合は未達・使用量・次手を報告する。予算到達を成功へ置換しない。勝手に予算を増やしたりGoalを作り直したりしない。
- `no-progress` / `oscillation`: 同じ修正の往復を止め、具体反例へ縮小するか安全な別残件を進める。全体が外部要因で進められない場合だけ、根拠と必要な最小判断を報告する。
- `poisoned-baseline` / `regression`: checker既存不通と新規退行を区別する。未証明の課題をdoneにせず、当該sliceを切り分ける。他者WIPを巻き戻さない。
- `harness-unavailable` / `app-hang`: 観測不通と対象故障を区別し、live受入を未確認にする。単体greenへ置換しない。同じ観測エラーを連射しない。
- `scope-boundary` / `git-write-blocked`: 禁止操作・新しい高インパクト判断・未知lockで影響する操作だけ保留。安全な残件は続け、境界の無断解除や新規委任をしない。

## 報告

途中報告はcommentaryで{実施 / focused結果 / 未達 / 次手}を短く示し、その後も続行する。最終報告は全受入達成、実際の予算上限、または安全な作業が尽きた具体的な阻害要因がある場合に限る。全体の残件とreview未実施を隠さない。承認済み項目の再承認、計測していない「劇的改善」、未commit/未反映の完了宣言は禁止。
