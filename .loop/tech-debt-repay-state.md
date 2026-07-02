# Loop state — 技術的負債の返済

## Budget
iteration cap 12 / no-progress streak 3 / wall-clock 120min

## Done
- [it0] pre-gate 6段ラダー全緑（leak pass / shellcheck 0 / js-check 0 / plugin 56 tests fail0 / swift build 25.7s / swift test 227 pass, 1 skipped, 0 fail）。baseline 健全 = poisoned-baseline なし。TD-01 = pass。
- [it0] 負債マップ完成: Explore 3並列（Core / UI・Relay・Tmux / JS・scripts・docs）→ `.loop/tech-debt-map.md` に統合。ledger 27項目（TD 12 = 今回返済、ES 15 = escalated 提案済 `.loop/tech-debt-escalations.md`）。main が一次ソース spot-check 2件実施（dead export 参照ゼロ / ISO formatter 混在を実測確認）= 委任成果の鵜呑みなし。実コード変更ゼロ。

- [it1] TD-02 pass: shared-state.test.js 新規（4 suite / 35 test、src 変更ゼロ）。post-gate main 独立実測 green（plugin 95/0, leak, js-check）。commit 56641f6。
  - 発見メモ: lookupTprojOrigin が内部レコードをそのまま返し `ts` が漏れる（JSDoc 型と乖離）。挙動はテストで固定済み。修正は次 run 候補（内部 state 漏れの解消）。

- [it2] TD-03 pass: context-cache.test.js 新規（12 suite / 31 test、mock.module で fs 依存 builder をスタブ化、src 変更ゼロ）。post-gate main 独立実測 green（plugin 126/0, leak, js-check）。
  - 発見メモ: deduplicateTrailAgainst のコメント「>50% で drop」と実挙動「>=50% で drop」が乖離（テストで現挙動固定済み）。filterPaneNoise 末尾の \n{3,} collapse は実質デッド。どちらも次 run 候補。
  - **TD-06 への注意**: TD-03 のテストが dead export（clearProgressSnapshot / getKnownProjects）もカバーした。TD-06 で export を削除する際は、対応するテストも同一 commit で削除すること（export 削除に伴う正当な除去であり test-weakening ではない）。

- [it3] TD-04 pass: context-reader.test.js 新規（6 suite / 18 test、tmp fixture・非 git dir で決定論化、src 変更ゼロ）。post-gate main 独立実測 green（plugin 144/0, leak, js-check）。export 疑惑2件（extractReferencedFiles/smartTruncate）はテスト import により正当と確定 → 削除不要。
  - 未検証領域メモ: 実 git 状態での builder 成功系（getGitInfo 等 private）は fixture 非 git のため対象外。

- [it4] TD-05 pass: RuntimeRoleTests.swift 新規（10 test、AppConfig.default ベース、RFC 5737/3849 fixture のみ）。post-gate main 独立実測 green（swift 237/1skip/0fail, build, leak）。safety-net phase 完了（TD-02〜05）。
  - TD-09 向け固定事項: RuntimeRole 集合は `::` を含み .server 判定 / 完全一致セマンティクス（port 付き・subdomain は loopback 扱いしない）/ runtimeRole は persisted nodeRole を無視。単一定義化でこれを壊すな。

- [it5] TD-06 pass: dead export 2関数を関数ごと削除（clearProgressSnapshot / getKnownProjects、33 del）+ TD-03 対応テスト除去。削除前 grep 三重確認で production caller ゼロ（機能の無断削除に非該当 = 呼ばれない関数は機能ではない）。post-gate main 独立実測 green（plugin 142/0, leak, js-check）+ diff 目視。

- [it6] TD-07 pass: BridgeCore の ad-hoc ISO8601DateFormatter 4箇所 → Self.isoFormatter に統一（4行同型置換のみ）。共有側は素の default 生成で出力バイト同一を事前確認 = 同値変換。post-gate main 独立実測 green（swift 237/0, build, leak）。

- [it7] TD-08 pass: 18789→AppConfig.defaultOpenClawPort / 8765→BridgeServer.defaultPort に集約（意味別2定数）。doctor message は実値化せず定数 interpolate（BridgeServer は main.swift で port 省略構築 = 定数が常に真値、divergence ゼロ）。出力 byte 同一。post-gate main 独立実測 green（swift 237/0）。
  - out-of-scope candidates（agent 申告、未変更）: main.swift/QRCodeView/SettingsView の UI・log 面のポートリテラル、BridgeCore:1507 コメントの "8765" 表記。次 run or 御主人様判断。

## Failed / blocked
（まだ無し）

## Next step
ITERATION 8: TD-09 loopback ホスト集合の単一定義化（BridgeCore.swift:2158 の集合は `::` 欠落、RuntimeRole.swift:23 と不一致）。TD-05 の RuntimeRoleTests が安全網。**注意**: 統一により BridgeCore 側の判定に `::` が加わる = 厳密には挙動変更。BridgeCore:2158 の用途（forward-target 判定）で `::` を loopback 扱いに変えて安全かをコード文脈で確認し、疑義があれば escalate に切替（ledger の verify 欄に明記済み）。post-gate は swift build + test。
