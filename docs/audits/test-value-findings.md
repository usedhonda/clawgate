# テスト価値・乖離 所見台帳

監査範囲・実験E1–E4・限界は[test-value-audit.md](test-value-audit.md)。T番号は[test-value-cases.tsv](test-value-cases.tsv)に対応する。優先度P1は偽陽性/安全上の誤認、P2は弱い保証/継続性欠落、P3は整理・保守効率。**すべて提案。削除・置換は未実施。**

## F01 — 局所値比較でnavigationを保証していない

- P1 / replace / T0487–T0489。
- `LINEAdapterTests.swift`で同じhint、異なるhint、nilを局所値だけで比較。本番`LINEAdapter.swift`のskip判断・既定conversation保護・入力欄存在確認を呼ばない。
- 本番参照: `ClawGate/Adapters/LINE/LINEAdapter.swift:156`。同値だけでなく入力欄と既定conversation条件、送信成功後のcache更新までが実契約。
- 採用条件: 本番の判断入口を実行し、same/different/nil/default/input-missingを区別。既存3件の定数assertを残すだけでは不可。

## F02 — HTTP routeの期待結果をテスト側で再実装

- P1 / replace / T0320。
- `BridgeRouteMatrixTests.swift:124`の`wouldReturn405`はローカルpredicate。実`BridgeRequestHandler.handleRequest`の405/404 responseを検査しない。
- 本番参照: `ClawGate/Core/BridgeServer/BridgeRequestHandler.swift:186`。
- 採用条件: 実handlerにmethod/pathを渡しstatus/bodyを検査。route lookup単体のT0318/T0319等とは保証を分ける。

## F03 — ingress正規化12件がコピーを試験

- P1 / replace / T1262–T1273 / E1。
- `line-ingress-noise-filter.test.js`は複数の正規化関数をinlineコピー。一部の実helper/定数をimportしていても、主要なnormalizationは本番でない。
- 本番: `extensions/openclaw-plugin/src/gateway.js:1648`以降のnoise/wrap/normalize、consumerは同`:4950`。
- 実normalize入口を例外にしても12件PASS。**現行の出力不一致が実証されたわけではなく、将来の乖離を検出できない構造**が確認された。
- 採用条件: 同じ12シナリオを実ingressの純粋入口またはconsumerに適用し、対象本番の故障で落ちること。シナリオ削除では解決しない。

## F04 — session keyのconsumerを縮小コピー

- P1 / replace / T1340–T1341 / E1,E2。
- test内splitは本番`outbound.js:20`のsession mode判定、および同`:103`のorigin lookupを省略。
- producerの5件まで無価値とはしない。実`outbound.sendText`を通る既存テストは同mutationでFAILした。
- 採用条件: 実producerが生成したkeyを実outbound consumerへ渡し、autonomous/observe/unknown modeとorigin lookupを含む契約を検査。

## F05 — empty scanの結果を検査しない

- P2 / strengthen-or-consolidate / T0329、関連T0333。
- nonexistent rootでmanager.scan()するだけ。no-crash以外のassertなし。T0333はselectedName/current/charactersを観測するが、入力境界の同一性を確認せず削除しない。
- 採用条件: nonexistent-root時の空一覧・fallbackを明示してassert、または同境界をT0333へ移管。

## F06 — clipboard stressの名称とoracleが不一致

- P2 / strengthen / T0371、比較T0370。
- 100並行操作の完了待機しかassertせず、最後のcheck後もoffer==0を見ない。名称のOfferFreeを保証しない。
- T0370のdeterministic semaphore検査はoffer 0を検査しており保持する。
- 採用条件: 処理完了と無offerを別々に観測。stress量を増やすだけでは改善しない。

## F07 — native UI fixtureは性能回帰gateではない

- P2 / manual-only / T0357。
- opt-inでrunloop timer latenessのp95/maxを表示。main-threadと30秒以内完了はassertするが性能閾値がない。測定名もinput-to-displayではないと明示されている。
- 採用条件: 診断fixtureとして保持。性能保証とする場合だけ、対象操作・計測区間・環境・閾値を定義。利用者の体感をこのPASSで否定しない。

## F08 — bundle欠落をsource fallbackが隠す

- P2 / split-and-strengthen / T0325。
- Bundle.module、列挙、repository resourceの順にfallbackしてparse。resource packagingが壊れてもsource側で通る。
- 採用条件: parser fixtureとbundle存在を分離。bundle契約側ではsource fallbackしない。

## F09 — 非default設定の読取を示せない

- P2 / strengthen / T1335。
- configured agentがdefaultと同じ値。常にfallbackを返す実装でも通り得る。
- 採用条件: 非default agentと複数候補を使い、設定値選択とfallbackを分離。

## F10 — highest scoreの比較対象が1件しかない

- P2 / strengthen / T1075。
- 候補Aはframeなし。geometryHintがある実resolverはframeなしを除外するためBだけが残る。assertも結果/frameのnonnullだけ。
- 本番: `ClawGate/Automation/Selectors/SelectorResolver.swift`のframe guard。
- 採用条件: 両方有効な候補に異なるscoreを与え、winner identityをassert。現ケースはmissing-frame除外として再命名・保持可能。

## F11 — 時刻更新を非減少でしか検査しない

- P2 / strengthen / T1003。
- 注入clockを15秒進めるが`second >= first`なので未更新でも通る。
- 採用条件: 注入した2回目の時刻との一致（または厳密な差）をassert。

## F12 — 空historyだけでは除外仕様を守れない

- P2 / strengthen / T1097。
- todayだけをseedしてemptyを期待。常にemptyを返す実装も通る。
- 採用条件: prior-dayが残りtodayだけ除外される正負同時のfixture。現在のnegative vector自体は保持価値がある。

## F13 — 音声出力診断と実際の可聴性は別

- P2 / manual-only / T1025、関連T1024。
- nilはplayableという契約のためassertなしで正常終了し得る。これだけをbugと断定しない。T1024は合成WAVの波形を検査するがspeakerから聞こえた保証ではない。
- 採用条件: ハードウェア診断と合成回帰を分け、実音声の受入証拠に数えない。

## F14 — MenuBar truth tableの重複

- P3 / consolidate / T0717–T0719。
- T0717内に同一assertの反復。T0719はT0718の一入力と一致し、実activation eventは起こしていない。
- 採用条件: 可視性/frontmost/key条件の一意な表に統合。非同一条件は保持。

## F15 — LINEAdapter suite内のhelper検査重複

- P3 / consolidate / T0490–T0494。
- 対応: T0490→T0998/T1000、T0491→T0558、T0492→T0556、T0493→T0557、T0494→T1002。
- T0493のtimestamp入り長文vectorは失わない。T0494はlatest textだけで、コメントが示すconversation cache-on-successは未検査。
- 採用条件: specialized suiteに固有vectorを移管し、adapter integrationという誤認をなくす。cache保護はF01の実consumer側で検査。

## F16 — outboundの部分的なassertion包含

- P3 / consolidate / T1306↔T1318、T1308↔T1319。
- 後のケースは同routeに加えunprefixed text/no queueを検査する。統合候補。
- textとmediaは異なるpublic entrypointなので同じmappingでも機械的に削除しない。

## F17 — runtimeRoleの大きなsuiteとの重複

- P3 / consolidate / T0134↔T1043/T1048/T1052。
- dedicated RuntimeRoleTestsに同じ役割契約がある。入力ごとの差分を移管したうえで総合集約側を整理する候補。

## F18 — parserの同一middle-subset負例

- P3 / consolidate / T0188↔T0208。
- 同じallowed segment順序、middle subset、high confidence、automaticBackward、同じfailure期待。T0188には別の正しいsuffix正例もある。
- 採用条件: 正例を残し、同じ負例の実行を1箇所に集約。歴史的なbug説明はコメント/台帳に維持。

## F19 — positionedと命名しているが位置付き経路でない

- P3 / consolidate-or-rename / T1136、関連T1122/T1127。
- 実行は同じ`VisionOCR.isChromeLabel`。位置情報を使う実pipelineを通らない。
- 採用条件: 固有のmessage vectorを保持しhelper testへ統合、またはpositioned consumer経路を追加。OCR実画像の精度保証とは別。

## F20 — SSE通信失敗が無条件PASS

- P1 / strengthen / `scripts/integration-test.sh:139` T3.3 / E3。
- `curl ... || true`の次に無条件pass。timeout以外の接続失敗も隠す。
- T2.1はnonempty bodyだけでpassするのでdoctor healthyの保証ではない。T5.1にはexpected skipもあり、全PASS表示は実送信完了を保証しない。
- 採用条件: transport exit、HTTP、SSE header/eventを目的に応じて検査。許すtimeoutと接続拒否/不正応答を区別し、skipをpassに数えない。

## F21 — strict sendが空応答を成功にする

- P1 / strengthen / `scripts/macmini-colocated-e2e.sh:106` T4/T5 / E4。
- error.codeのempty/nullをsuccessに扱うため、空応答/不正JSONでも通り得る。T4を隔離ブロックで再現。
- 採用条件: transport/HTTP成功、有効JSON、明示的な成功値、必要ならreceiptを確認。LINE/tmux双方で負例を持つ。

## F22 — 現行構成と運用テストの前提が不一致

- P2 / update-or-retire / colocated T2、federation-verify、verify-cc-observe、legacy2本、IntegrationNotes。
- colocated T2は`remote.node_role`を要求。本番`BridgeCore.config`はその値を意図的に公開しない（T0317）。旧relay port/federation接続を前提にする検査と現行app経路を混同しない。
- `scripts/legacy/README.md`でlegacy2本は既に退役資料と明記。`Tests/IntegrationNotes.md`の旧AppBridge/token401前提は現行handlerのsource-IP/Origin保護と別物。
- 採用条件: 対象topologyを明記し現行契約へ改訂。退役資料は現行gateから除外するが、本人指示なく削除しない。

## F23 — proxy runnerが存在しないentrypointを参照

- P2 / repair-or-retire / `scripts/proxy-macmini-e2e.sh:23`。
- 呼出先`run-macmini-relay-and-e2e.sh`は現在のcheckoutに存在しない。実行結果/成功を作れない。
- 引数をmetadataへ保存するためtoken引数を渡した運用では漏洩リスクもある（実資格情報は読取/投入していない）。
- 採用条件: 正規entrypointとsecret-free metadataに整合。旧構成専用なら退役を明示。

## F24 — traceのFAIL表示が終了コードに反映されない箇所

- P1 / strengthen / `scripts/line-e2e-trace.sh` pipeline emitted=false分岐。
- `fail()`は表示のみ。該当分岐はexit/count増加せず後続へ進める。replyはflagなしで任意、logのsending replyは受領証明ではない。
- smoke S5は過去tail内doctor OKとinconclusive cursorでもpass。freshness/correlationが弱い。
- 採用条件: 必須phase失敗は終端FAIL。期待eventの時刻/IDを相関させ、送信開始・gateway観測・相手受領を別々に記録。

## F25 — CI未接続

- P2 / wire-after-isolation / Chrome47件、shell/Python7本、leak selftest10件。
- `.github/workflows/ci.yml`でbehavior実行がない。JS syntax/ShellCheck/leak scanは各テストの代わりにならない。
- 採用条件: 安全で独立した実行環境、適切なruntime、明示的なskip集計を整え、必要な入口だけ接続。実機操作を無条件CIへ足さない。

## F26 — harness自体の固定作業領域とmockの保証限界

- P1（隔離）/ P2（保証） / isolate-and-retain。
- rollout-residualsはrepository `.runtime`の固定manifestと決定的stageを削除する。並行運用candidateと衝突し得る。restart-guardにも固定作業名あり。この監査では実checkoutで実行しなかった。
- restart-guardのcanonical fake自身がcheck/stop/apply/startを出力するため、その列のassertはwrapper wiringの保証であって外部canonical内部の順序保証でない。
- maintenance-order、signed-bundle-preserve等の実local shell/bytes検査は保持価値あり。mockされたSSH/signing/healthまで実証したと言わない。
- 採用条件: per-run temp rootへ隔離し、実helper/side effect境界とstubを明示。wrapper-branchesの既存stage拒否保護は維持。

## F27 — CI smokeの再実行と差分判定

- P3 / consolidate / `.github/workflows/ci.yml` line-smoke。
- full suiteで対象になるSwift subsetとoutboundを再実行。別実機/別oracleではない。job条件に`|| true`があり常時評価、実stepのguardはHEAD~1..HEADでPR全体と一致するとは限らない。
- 採用条件: fullの結果と明確に異なる価値がない再実行を集約。LINE変更検出を安全検査の唯一入口にしない。

## F28 — source文字列は動作保証でない

- P2 / replace-or-document / T0058–T0059、T0741、T0801、T0803–T0809、T0812、T0819–T0820、T0932、T0951–T0952、T0993、T0997。
- 綴りを含む/含まないことを検査。dead codeやcommentでも通り、無害なrefactorで壊れ得る。UI label/docs contractは意図を明記すれば限定的な価値がある。
- 採用条件: subscriber反映、teardown後無更新、tab消費など実動作へ置換。静的guardは補助と明記。
- **保持する静的guard**: T0372–T0373のclipboard mutation規約、T0769のraw ping禁止、T0904の実store混入禁止、T0930の仕様version同期、T0931/T0944のprivacy補助。これらも動的E2Eや完全漏洩検知ではない。

## F29 — framework実演とproduction bindingを区別

- P3 / supplement-or-consolidate / T0054。
- Publishedのstale rereadを示す有用な説明だが、実UI subscriberの正しさまで試験しない。
- 採用条件: 実subscriberで更新が届く回帰を持つ。framework実演を残すなら説明用と記載。

## F30 — 必須stale pending解除の回帰が未検出

- P1 / coverage-gap / 対応Tなし。
- `gateway.js:2085`の`detectInteractionPendingFromCompletion`、10分超stale削除と`:3761`の呼出。本project契約に明記されるが、テスト内の直接/名前付きカバーを検索で検出できなかった。
- `resolveInboundCommandAuthorized`も同様。完全な動的非到達を数学的に証明したわけではない。
- 採用条件: old pending + 現証拠なし→削除/抑止解除、old pending + 現waitingReason/options→必要な抑止維持、新pending、境界時刻を実処理で検査。認証はallow/deny実経路を別に確認。

## F31 — unit PASSをネット復旧/日本語生成E2Eに数えない

- P2 / retain-with-limit / T0603–T0609、議事録/日本語prompt関連。
- 実queue/state/hookの回帰は重要。一方、実NWPathMonitorの回線断→復旧、実STT、実LLM日本語回答、画面完了までを連続して実行した証拠ではない。
- prompt文字列assertは日本語指示の送出を守るので保持。LLMが従うかとは別。
- 採用条件: unit保証を維持し、実機受入が必要なら独立した明示的シナリオとして扱う。今回その操作は実施していない。

## F32 — production store保護テストの実データ接触

- P1 / isolate-and-retain / T0905–T0906。
- 実ログのbefore/afterを読むことで本番path拒否を検査。保護が壊れたmutationを実account上で試すと原データに接触する危険がある。
- 採用条件: 偽のproduction-rootを注入可能な隔離環境で拒否を試験。安全保証自体は削除しない。

## 保持判断の原則

storage破損検出、atomic write、ACK喪失/replay、source revision、権限・path traversal、停止後の古い結果排除は、小さな単体テストでも高価値。URLProtocol/VM/clock injectionは決定性を与える境界であり、mockがあるだけでは低価値としない。ChromeのVMテストは実content/meet/ocrスクリプトを実行しておりF03のコピーとは異なるが、実ブラウザDOMとの互換は別証拠。AmbientCaptureManagerのDEBUG wrapperも実write/prime/finalize処理を呼び、単なる再実装ではない。

実装採用前には対象行の現在hashと同じかを確認し、古い所見をそのまま現在の不具合と扱わない。台帳更新は変更対象だけとし、緑suiteを繰り返して監査量を水増ししない。
