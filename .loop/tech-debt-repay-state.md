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

- [it8] TD-09 pass: AppConfig.loopbackHosts に単一定義化（RuntimeRole + BridgeCore forward-guard の inline 集合2つを置換）。`::` 差分の分析: 現挙動は到達不能 "http://[::]:8765" へ 9s timeout 失敗、統一後は即 503 line_forward_unavailable(retriable) = fail-closed 改善、新エラーコード無しで contract 不変。cleanup phase 完了（TD-06〜09）。post-gate main 独立実測 green（swift 237/0）。

- [it9] TD-10 pass: OpsLogSummarizer.swift 新設（humanReadableSummary/parseMessageFields/parseKeyValueMessage/shortProject + leaf 依存 compactMessage 同伴、MenuBarApp -96行）+ OpsLogSummarizerTests 23本を同一 commit（1 fix + 1 guard）。post-gate main 独立実測 green（swift 260/0）。
  - out-of-scope candidate: parseKeyValueMessage の別コピーが BridgeCore.swift:2369 に存在（BridgeCore 内部4箇所で使用）。2コピーの一本化は次 run 候補。

- [it10] TD-11 pass: PetGeometry.swift 新設（roughlySameFrame 全移動、y 反転式は desktopMaxY 引数化で純粋抽出・NSScreen wrapper は PetModel 残置）+ PetGeometryTests 9本（involution 性質含む）。separation phase 完了。post-gate main 独立実測 green（swift 269/0）。

## Failed / blocked
- **[規律違反の自己申告・要御主人様報告] TD-11 が Pet 所有権ルールに抵触した疑い**: memory `feedback_pet_tracking_cdx_required.md`（P0, 2026-04-11）は「PetModel.swift の tracking/hide/facing/movement 編集は Cdx 所有、CC 直接編集禁止」。TD-11 の抽出対象（roughlySameFrame / appKitRectForTrackedFrame）は window tracking で使われる関数で該当の可能性が高い。loop contract の OFF-LIMITS 設計時にこの memory を見落とした（map 作成時も検知漏れ）。是正: 所有者 Cdx に commit 50f4114 の ratify/reject レビューを依頼済み（reject なら CC が即 revert = CC 単独許可範囲）。**教訓: off-limits 設計時は CLAUDE.md だけでなく memory/ の P0 feedback 群も走査すること**（learnings 昇格候補）。

- [it11] TD-12 pass: OpenClawGatewayInfo.swift 新設（token/port/host? の共通 parse 一本化、host fallback は各呼び出し側残置 = 2サイトの挙動差維持）+ OpenClawGatewayInfoTests 7本。BridgeCore -8/+4、WSClient -11/+2、PetModel 不触。**full ladder 全緑を main 独立実測**（leak / shellcheck / js-check / plugin 142/0 / build / swift 276 pass 1 skip 0 fail）。全 TD 12項目 pass。
  - arch doc 整合: reference_architecture.md の「読み手」記述（BridgeCore /v1/openclaw-info, PetModel readOpenClawGatewayConfig）は現状と一致、reader 新設は内部実装の変化のみで doc 更新不要（Arch doc: current）。

## Next step
FINAL 前の独立完了チェック（maker != checker）: fresh sub-agent に ledger + contract SUCCESS CRITERIA + 直近 diff を渡して検証。PASS なら FINAL（TD-11 の Cdx ratify/reject 判定は pending のまま報告に含める）。
