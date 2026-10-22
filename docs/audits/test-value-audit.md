# テスト価値監査

## 結論

2026-10-22 の作業ツリーを対象に、**Swift 1,154件、JavaScript 237件、計1,391件**を宣言単位で棚卸しした。テストファイル160本にはケースを持たない共有helper 1本を含む。別にShell/Python/運用チェック17本、CI、fixture、実行条件を調査した。

最優先はテスト数の削減ではなく、**壊れた本番を見逃す判定の解消**である。本番処理を呼ばないコピー、通信失敗でもPASSする運用チェック、assertionのない検査、名前より弱い判定が見つかった。重複は統合候補であり、削除承認ではない。

この変更は**監査資料のみ**。本番コード・テストの変更、削除、全suite実行、実機送信、再起動、公開は行っていない。

## 台帳

| ファイル | 内容 |
|---|---|
| [test-value-cases.tsv](test-value-cases.tsv) | 全1,391件。入力シナリオ名、保護対象、assertion式、helper/呼出候補、実装参照、判定、関連所見 |
| [test-value-candidates.tsv](test-value-candidates.tsv) | 改善候補66件の抽出。置換・強化・統合など64件、保護テストの隔離改善2件。削除リストではない |
| [test-value-files.tsv](test-value-files.tsv) | 全160ファイル。保護契約、主な実装、境界、CI入口 |
| [test-value-scripts.tsv](test-value-scripts.tsv) | 17本・97検査段階。目的、判定、実行副作用・制約（宣言ケース数とは別単位） |
| [test-value-findings.md](test-value-findings.md) | 優先順位付き改善候補と保持すべき保証、採用条件 |
| [test-value-snapshot.tsv](test-value-snapshot.tsv) | 監査対象のパス・SHA-256。dirty/untrackedを含むスナップショット |

TSVはUTF-8、1レコード1行。表計算ソフトでタブ区切りとして開ける。ケースIDはこのスナップショット内の参照であり、将来の再採番と混同しない。恒久的な照合キーは`path + test_name`。行番号は監査時点のもの。

## 範囲と読み方

- 起点HEAD: `a5dc19dbf8740eb126300aa15cfeb609f5a2bece`。作業中の議事録修正・追加テストも含むため、HEADだけでは再現できない。
- `git ls-files --cached --others --exclude-standard`からテスト宣言を収集し、独立した宣言検索と照合した。未追跡だが非ignoreのテストも対象。依存パッケージ、build生成物、ignored個人fixture/実データは対象外。
- 全ケースのシナリオ・assertion一覧を静的に確認。疑わしいものはhelper、本番実装、呼出側まで追跡した。**全ケースについて実機E2Eや完全なcall graphを証明した監査ではない**。
- `protected_contract`はファイルの責務、`scenario`は個別テストの意図。`oracle`はassertionの実際の式で、個人情報を含み得る文字列・正規表現は伏せてある。具体値と前処理は`test_source`を参照する。
- `production_refs`の行単位参照は識別子一致による静的探索であり、到達性証明ではない。`family_sources`はファイル単位の本番境界。`calls`もテスト内の字句上の呼出候補で、helperやfixture生成を含む。
- `retain-candidate`は「静的確認で低価値とする根拠なし」であり、全経路の品質保証やmutation合格を意味しない。`strengthen`、`replace`、`consolidate`は**候補**。`manual-only`は自動回帰ゲートと混同しないという分類。
- `helper-oracle`はassertionがhelper側にある。inline assertionがないだけでは無価値としない。prompt本文の文字列契約も、単なる実装綴り検査と区別した。
- 同じACK/queueを複数層で検査していても、永続化、transport、producer、consumerの故障境界が違えば重複ではない。
- 正規化したテスト本文の完全一致は0組。ただし意味的な重複は存在する（F14–F19）。
- 共有JSON fixture3本はwire/signingの入力資料としてsnapshotに収録。fixture自体を独立テストとして水増ししない。`MinutesPreparationTestSupport.swift`も同様。

### ケース判定の集計

| 分類 | 件数 | 解釈 |
|---|---:|---|
| 保持候補 | 1,308 | 静的調査で低価値とする根拠なし。実機/完全な経路保証はしない |
| 静的規約guard保持 | 7 | 禁止API・privacy・仕様同期などの補助検査 |
| 手動/opt-in | 10 | 通常CIの自動保証としては数えない |
| 置換・強化・統合等の候補 | 64 | 特定の弱いoracle・コピー・重複・意味の不一致。個別理由はF所見 |
| 保護テストの隔離改善 | 2 | 保護契約は保持し、実データへの接触をなくす候補 |
| 合計 | 1,391 | 宣言数。parameterized入力やhelper assertionの数ではない |

## 調査・実験の証拠

| 証拠 | 操作と結果 | 言えること / 言えないこと |
|---|---|---|
| E1 | 隔離コピーの本番`normalizeInboundText`、`devLanePaneProject`、`tprojOriginForSessionKey`入口を例外に変更。noise-filter + session-keyの19件が19件ともPASS | コピー実装を使う12+2件は対象本番破壊を検知しない。残り5件はproducer側で、consumer破壊に失敗するとは期待していない |
| E2 | 同じコピーの実`outbound.sendText`を通る`autonomous tmux sessionKey routes to pane`を1件だけ実行。挿入した例外で期待どおりFAIL | mutationが有効で、本番consumerを通るテストなら検知する。通常suiteの回帰FAILではない |
| E3 | `integration-test.sh`のT3.3判定ブロックを切り出し、curlを終了7のshell関数に置換。exit 0 / PASS | 接続拒否でも成功になる。ネットワーク接続・SSE送受信は実施していない |
| E4 | colocated E2EのT4と元のJSON helperを切り出し、remote curlを空応答に置換。exit 0 / PASS | 空応答を送信成功扱いする。実LINE送信は実施していない |

mutationはignored領域のコピー内だけで実施した。原テスト・本番ソースは変更していない。実験ログはローカル監査領域に保管し、公開台帳に生ログ・fixture本文・資格情報を転載しない。時間値は性能評価に使用しない。

## CIと実行されない保証

参照: `.github/workflows/ci.yml`、`Package.swift`、pluginの`package.json`。

| 面 | 現状 | 判断 |
|---|---|---|
| Swift | CIで`swift test` | 1,154宣言が存在することと、全件が実行されることは別 |
| plugin | CIで19ファイル・190宣言を対象にNode test | 本番importの有無は別途ケース台帳で区別 |
| Chrome | 7ファイル・47宣言。CIのJS syntax checkのみでは実行されない | 回帰保護が自動ゲートに入っていない（F25） |
| Shell/Python harness | 7本。CIはShellCheckでありbehavior testではない | fixture隔離を直してからゲート候補にする（F26） |
| leak guard | CIで`--all`。`--self-test`の10ケースは別 | スキャン実行とスキャナ自身の回帰試験を区別 |
| LINE smoke | full Swift/plugin対象と重複するsubsetを追加実行 | 独立した実機E2Eではない。検知範囲を増やさない再実行（F27） |

既定ではskipし得るSwift10件: T0033–T0035、T0357、T0414、T0422、T0576、T0578、T1024–T1025。STT音声fixture、live ingest、native UI計測、private画像、calendar/archive、音声出力のopt-inが必要。Reminderのenum `.skip`はXCTest skipではない。

追加の未検出領域: `tools/diarizer`にtest targetなし、`extensions/vibeterm-telemetry`にテスト未検出。`pendingQuestions`の10分超stale解除（AGENTS必須契約）、`resolveInboundCommandAuthorized`に対応する直接/名前付き回帰ケースも検索で未検出。これを「本番で不具合が発生中」とは断定しない。

## 修正に進む場合の順序（今回未実施）

1. F20/F21のfalse PASSをfail-closedにし、通信失敗・空応答・不正JSONの負例を保持。
2. F01–F04のコピー/局所式を実consumerを通る検査へ置換。シナリオは維持。
3. F05–F13の弱いoracleと名前の不一致を修正。実測fixtureは診断用途を明記。
4. F14–F19を代表ケースへ統合。ただし異なる入力境界は残す。
5. F22–F27/F30–F32の運用構成、CI入口、実データ隔離を整合させる。

各採用条件は所見台帳に記載。優先度は「誤った安心を与える危険」であり、行数やテストの小ささを価値の代理にしない。全suiteの繰返しや本番操作は監査の完了条件に含めない。

## 完了境界

資料検査: 1,391件のID/宣言/元行番号一致、160ファイルとの件数一致、17script/97段階、関連IDの参照整合を確認。414対象パスのsnapshot hashと現在の内容が一致し、監査で既存sourceを変更していないことを確認した。新規資料に対する正規leak-check関数と追加のpath/address/token検査はPASS。資料検査の初回は列数の期待値を16と誤記して失敗したが、実際の15列schemaに合わせて訂正した（本番・テストの失敗ではない）。

台帳全件収録・所見整理・隔離実験・資料整合確認まで。修正実装、テスト削除、release、Kai/peerレビュー、新規agent作成はこの監査では実施していない。既存のunknown Git lockと作業中差分を保全し、commit/pushも行っていない。
