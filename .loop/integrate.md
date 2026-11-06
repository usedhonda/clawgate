# LOOP: 複数資料の議事録統合を完遂する

KIND: closed
VERSION: 1
STATUS: autonomous scope delivered; owner requested termination; 実証拠はstate参照
GOAL: 同じ会議の音声・文字起こし・既存議事録を出典を失わず一つの議事録に統合し、HubとChiの統合先参照、既存7組の整理、ローカルとリモートへの正規反映、実受入まで完遂する。
STATE: `.loop/integrate-state.md`
HOST: 現在のCodex会話。生成時get_goalはnull。create_goal/get_goal/update_goalが公開されている。slash起動面は未確認なので通常のcreate_goal指示を使う。

## 原依頼とProject Profile

正本は直前に提示した「複数音声・既存議事録の統合を完成させる計画」。本人のImplement指示と今回のGoal契約生成依頼を保持する。既存議事録のみの情報も出典と【既存議事録・原音未確認】を付け、決定・担当を含め採用する選択は確定済み。同じ承認を再質問しない。

成熟したSwiftPM/macOSアプリ。既存のfusion、分割生成、実行台帳、accepted保存、Hub/Chiの独立配信、署名済み配備経路を使う。新daemon、別DB、汎用runnerは作らない。正本はacceptedファイル、exportは派生。入力の原文・時刻・出典と受理済み旧版を保全する。

生成時の確認: mainは74cd6c9。隔離branch feat/minutes-evidence-integrationの5c98024に、比較時だけの時計補正・既存議事録の引用付き採用・ラベル検証・UI分類がある。rootにも対応する未commit差分が残る。既存記録はfusion8件、secondary2件の成功とローカルbuild/restart exit0を報告する。これは新しい全体統合、リモート反映、実受入の証明ではない。
進捗原本: `.local/minutes-loop/integration-implementation-state.private.json`。旧 `.loop/minutes.md` とそのstateは知識連携/Recallの履歴として保持し、本契約で上書き・再起動しない。本契約が今回の統合作業の唯一の継続ownerとなる。

## 実装契約と暫定実行順

1. 既存差分を照合して統合する。rootの他者変更・所有不明lockを保全。lockが残れば所有状況を限定確認し、既存隔離worktreeで独立作業を続ける。lock削除や他者変更の巻戻しを前提にしない。
2. 時計補正後の時間帯・正規化本文で、同じ発言と分割された連続発言を対応付ける。生成入力は代表文と全出典IDへまとめるが、原文は保存する。数値・否定・人物・期限の違いを重複扱いしない。言い換えは前処理で消さず全体統合で根拠を比較する。
3. 概要だけの書換えを、出典付きの論点・決定・担当・期限・未解決事項の全体統合へ置換する。明示的な根拠がある訂正/撤回だけ反映し、単なる後勝ちにしない。曖昧な矛盾は未解決として残す。長文は出典を維持して段階統合し、黙って切り捨てない。
4. 既存永続実行台帳に全体統合工程と入力版を結び付け、同じ入力から再開できるようにする。全体統合と検証が成功するまで旧acceptedを置換しない。旧概要経路も同じ完了条件へ接続する。
5. 既存Hub/Chi担当と正式な承認参照・対象・実行競合を照合し、受信側の契約/実装/反映を先に完了する。他列を勝手に編集せず、新しいagentは作らない。普通のMSG引用を機械承認へ変換しない。既承認scopeの検証経路の問題は正規task入口で解決し、本人へ同じ承認を繰り返し求めない。
6. producerの公開状態管理を接続する。以下の契約を両受信側が実装・反映した証拠が揃うまで新フィールドは送らない。
7. 既存7組を一組ずつ確認し、会議対応・入力資料・統合先を固定する。不明な組だけ保留し、他を進める。統合先本文/版の両配信先readback後に旧slotをsupersededへ変更する。元資料は保存し、失敗時は未完工程だけ再開する。
8. 正規のローカル再起動とリモートの署名済みapp配備を行う。配備runbookを直前に読み、録音選択と他サービスを維持する。Gateway共有配備は担当間で直列化する。実際の生成・配信・検索/参照を確かめる。

### 公開契約

- Publication envelopeにoptional `supersededBy: {sourceUUID, meetingID, outputRevision}`、receiptに`superseded`を追加する。upsertのみ。snapshotの未知フィールドは増やさない。
- 公開状態だけの変更ではexact snapshot bytes、payloadSHA256、outputRevisionを保ち、publicationOrdinalを進めpreviousRevisionを現headへ結ぶ。同本文版の状態変更を台帳で区別し、全immutable envelopeで再送一致を検証する。
- 同source内の別meetingだけ。指定時の統合先は現在版が一致し、受領済みでdelete/supersededでないこと。自己参照・循環・二段以上は拒否。複数旧slot→一つの統合先は許可する。既に他slotの統合先になったslotを別slotへ向けない。
- 通常検索では旧slotを除外し、直接取得では元本文と統合先を返す。Chiは既存get結果型のcontent先頭に内部で解決した参照と状態を示し、Hubは構造化した参照と状態を返す。既存agent/sandbox/privacy境界を保つ。
- target revisionは書込時の証拠。読取は統合先の現在headを解決し、更新/削除/未取得を区別する。旧slotは自動復活しない。解除は明示的な新連番upsert。過去再送では復活しない。
- receiptのisCurrentは現公開headを表し、検索可能の同義ではない。HubとChiのpending/receiptを独立管理し、片側ACKで他方のpayloadを捨てない。不可逆deleteを統合の代用にしない。

## SUCCESS CRITERIA / EVIDENCE MAP

全条件AND。未確認はpassでない。各証拠に対象commit・入力版・環境・観測時点・場所を記録する。変更した面だけ証拠を失効させる。

| ID | 条件 | 有効な判定と証拠 |
|---|---|---|
| I1 | 同一/分割発言の重複入力を減らし全出典を保持、不一致は保持 | 既存fusion検証を拡張する必要最小のケース。元文復元、全ID、数値/否定差が失われないassert。対象source/入力仕様変更で失効 |
| I2 | 会議全体の決定・担当・訂正/撤回・矛盾を根拠付きで統合 | 実行台帳とparserのfocused proof。根拠なし後勝ちを拒否、明示訂正を採用、secondary label保持。中断再開/失敗でaccepted不変。単なるsummary成功は不可 |
| I3 | 両consumerのsuperseded契約とproducer独立receiptが一致し反映済み | 各ownerの固定diff/契約、代表一次proof、配備結果。多対一許可/連鎖拒否/旧再送/直接get/target更新削除/片側失敗を確認。設計ACKだけは不可 |
| I4 | 7組それぞれの安全な統合が成立 | ignored manifestに各組の対応判定、統合先exact版の両方の本文readback、旧slot検索除外と直接参照、両receiptを記録。不明な組は残件とし件数で丸めない |
| I5 | ローカルとリモートに正規反映され機能経路が動く | scope commit、署名/installed版/復旧先、録音状態の前後、実UI/生成→配信→検索の観測。build/health200だけでは不可。別サービス無変更も対象を固定して確認 |
| I6 | 自然な複数資料会議とRecall代替の実受入が成立 | 本人選択と資料binding、原文→引用→accepted→配信先読取。RecallはClawGate/Meet側に議事録がない自然な対象が必要。未発生は未実施のまま、合成や勝手な履歴選択で代替しない |
| I7 | 全原依頼と結果の照合・引継ぎ保存・報告完了 | stateの引継ぎサマリーを読戻し、I1-I6の証拠と未完ゼロ、commit/反映/独立owner確認を報告。native completeはこの後のみ |

## VERIFY / 効率と独立確認

生成時にプロジェクトのテスト/ビルドは走らせない。実行時のfirst VERIFYは既存証拠を実対象に照合する。全部既に成立なら変更なしで完了可。green subsetなら未達条件へ進む。
アプリは既存SwiftPMの `swift test --filter MeetingFusionTests`、`swift test --filter MeetingMinutesSecondaryEvidenceTests` と変更対象の既存ledger/parserテストを再利用する。無変更のgreenは再走しない。新検証は正しい入力が通り、具体的な誤結果が落ちることを確認し、実装をなぞるだけのassertにしない。
各checkpointの必要な広域gateは最大1回。失敗はその単位だけ原因に応じて検証し、全suite再走やstash baselineを繰り返さない。consumer側のprimary proofは親が重複実行せず、統合diffと代表証拠を確認する。maker != checker: 自己採点ではなく客観的assert/readbackと、既存担当の境界確認を使う。独立確認が不足なら不足のまま保持し、レビュー用agentを新設しない。
build成功は完了でない。ローカルapp変更は既存 `scripts/restart-local-clawgate.sh` のplugin非変更手順、リモートは正規署名配備runbookを使用する。壊れた広域restartを盲目的に繰り返さず、原因と承認された狭い経路を照合する。署名identityを変更しない。

## 反復・状態・回復

1. 契約/state、git/worktree、Goal状態、実行中handle、取消、既存ownerを読む。同じstateへ同時に書かない。再開はリセットでない。不明な送信/配備はreceiptと実対象で照合してから次へ進む。
2. 原成果から次の未達条件を選び、仮説・期待観測・必要な最小作業を記録する。作業前に累積attemptを予約しrunningにする。中断したattemptも消費済みとして残す。コマンド1個をattemptとは数えない。
3. 最小の実装/診断/必要な修復を行い、対象条件の証拠を得る。終了時にexpected/actual、変化、次手、証拠をstateへ保存する。過去の詳細は既存private記録への参照で保持する。
4. 意味のあるslice終了時（greenでも）とテスト追加前に、触れた既存/今回追加テストを簡潔に点検する。異なる保証を保持し、根拠ある重複/廃止だけ局所整理する。価値不明は残す。全suite監査・削減ノルマ・新しい検査loopを作らない。
5. 同時に全体へ立ち戻り、利用可能な成果までの残距離と支配的な障害を確認する。テスト/helperだけ増える、観測が判断を変えない、同じ原因が絞れない場合は即座に簡素化・別経路・次の接続工程へ切り替える。必要な元要求を削らない。
6. 進捗は新しい成立条件、原因の排除、失敗範囲の縮小、実配送で測る。変更行数/ACK/同じ説明は進捗にしない。同じ失敗2回で新証拠なしなら同経路を繰り返さず再計画する。これは停止回数上限でない。

REMEDIATION SCOPE: 承認された統合を妨げる局所コード/台帳/正規scriptの修復、既存隔離checkoutでの継続、既存ownerとの正式接続修復を含む。初回障害から診断し、criterion→崩れた仮説→異なる正規経路→期待/実結果→戻る製品作業を記録する。単なる相談受領で止まらない。
- Git lock不明: 削除せず限定調査→隔離済みbranchでI1/I2→所有が解けた時点で統合へ戻る。
- consumer承認参照不足: 正規task能力/参照を一度診断→既存owner経路を接続→I3へ戻る。その間I1/I2等を進める。引用の再投入やidentityすり替えをしない。
- 配備失敗: 対象PID/版/署名/backupと原因を固定→許可された正規復旧/狭い経路→I5へ戻る。署名の自己流代用・権限迂回なし。
- 自然対象なし: I6だけ実受入待ちにし、I1-I5/I7の準備を続ける。候補不在を機能成功にしない。
META-LOOP BRAKE: 同じ制約と証拠不足のまま新しい連絡・計画・監視を増やさない。補助作業には解除条件と戻る製品作業を必ず付ける。未知locatorは許可済み範囲で限定探索し、見つからないことを即ユーザー禁止へ読み替えない。prompt規則はruntime強制機構ではない。

## 境界・native lifecycle・終了

録音ON/OFF、新規ASR、無関係な履歴再生成、原文削除、権限/鍵/model変更、public push、秘密表示、他列の無断編集、新規agentは禁止。修復範囲でもP0は優先し、該当操作を止め安全な独立作業を続ける。ユーザー観測を否定しない。通常の承認済み実装・commit・配備は再承認待ちにしない。scope単位commit、intent-guard、公開安全確認などrepoの必須契約を守る。

- 推奨Goal実行: 開始時get_goalで再確認する。未完Goalがなければ本GOALをcreate_goalで一度作成し実行する。明示token budgetなしなので指定しない。同じactive Goalは再利用し、別Goalを置換しない。
- 継続: checkpoint/ITERATING/一部テスト成功は終了でない。次の有用な承認済み作業を続ける。通常実行版も同じstateで複数工程を完遂するが、nativeの跨turn継続は設定しない。
- 完了: I1-I7すべての現在証拠が揃った場合のみFINALと報告し、Goal版はupdate_goal(status="complete")の実結果を報告する。native evaluatorは独立した検証実行者でない。
- pauseは本人の明示指示時のみupdate_goal(status="paused")。本契約に自動pauseはない。
- blockerは即記録するが、修復/正規代替/独立作業が全て尽きるまで終端扱いにしない。blockedは同一障害が3連続Goal turnで続くtool規則を満たす場合のみ。人工的なturn稼ぎ・Goal作り直し・completeによる停止は禁止。blocked再開controlは本tool群には無いので、実際のユーザー/host再開を確認する。再開後も累積状態を保つ。
- hard capは本人未指定。agent独自の回数/時間/トークン上限を作らない。実platform制約が来たら出所と消費/残りを保持し、未完checkpointで報告する。予算終了は成功でない。
- 全有用経路が尽きた場合、診断・試した修復または実行不能理由・残件・待つ相手/入力・解除条件をstateと会話へ残す。新monitor/scheduleは作らず、native停止規則に従う。

HANDOFF: stateの「引継ぎサマリー」を各意味のある境界と終了時に更新し、最後に読戻す。保存失敗時は最後の確定checkpointと失敗を報告し、保存済みと偽らない。
生成時の設計確認: 部分green→残作業へ、全証拠済み→無変更完了、lock→隔離作業、承認境界→独立作業、同失敗反復→経路変更、中断→既存receipt照合、自然対象なし→I6未完保持。いずれもscope/予算/既存履歴をリセットしない。

## 異常性レビュー後の整理（2026-11-06, task 65b4ecb7, 97c6c5e）

内容検証の必要条件（公開・配備・全件整理・自然Recall・報告のI3-I7も引き続き維持する）:
- 同じ会議の全資料を一つの議事録に統合し、内容を黙って落とさない（全sourceClaimの対応付け、全出力の根拠）。
- 訂正・撤回は原音の明示発言だけで採用し、既存議事録だけを根拠にしない。曖昧な食い違いは未解決に残し、決定・宿題に昇格させない。
- 実在しない出典を作らない。旧acceptedと原資料を壊さない。Hub/Chiの両方で統合先を読めてから旧版をsupersededにする。

自作の過剰機構（廃止・修正済み、以後この契約の条件にしない）:
- 中間stageごとにモデルへ全元IDを再転記させる全ID部分集合条件、履歴への全旧ID再転記、未知ID1個での全stage不採用。出典は固定sourceClaim対応から機械的に付け、未知IDは捨てる（97c6c5e）。
- 編集派生候補の別採用gate。保存済み生回答を修正済みparserで既存revalidation経路により再検証すれば足りる。候補2は不採用のまま保持。
- 毎分の状態照会、状態だけのcommit、ACKだけの連絡、確認済みproofの再実行。終端・失敗・実配送など判断を変える事象だけ記録・連絡する。

直列工程の結論:
- frozen jobは保存済み計画を保持する（再検証の要求一致のため）。
- 今後の選択統合jobは128k分割（本commit）。根拠は実観測: 第一組の統合stage入力は最大約728KBで受理・回答された（失敗はID再転記の検証だけ）。128kの通常promptは最大約410KBで観測範囲内。最終統合stageの大きさは分割幅でなく会議全体の引用量で決まるので、分割を広げても増えない。未着手pair2/3/4は計67呼出→17呼出（3+2/4+3/3+2）。256kは最大約800KBで観測範囲を超えるので採らない。
- 既存job（pair5の6分割など）は refreshingMetadata が分割数不一致で自身を保持するため凍結のまま。
- 失敗stageが後続を止める点は、二分木では後続が依存するため実害が限定的。変更しない。

## Owner-clarified completion boundary (2026-11-06)

The owner clarified that this Goal was intended to finish without further owner intervention, and requested Clear/termination. Close the already delivered autonomous implementation, canonical deployments, six real source-grounded integrations and both-destination/supersession acceptances; account for the seventh candidate's justified exclusion. Do not require a new owner-selected meeting or a future naturally occurring Recall case as this Goal's stopping condition.

The natural Recall real-data end-to-end check remains explicitly **not performed**, not passed or replaced by synthetic evidence. Preserve its selection/privacy/binding/all-page requirements for a future explicit task, but do not create another Goal, watcher or repeated owner question. I6's future-data portion and I7's former all-AND dependency are superseded only for closing the owner-clarified present scope. Historical evidence and the original acceptance intent remain recorded.
