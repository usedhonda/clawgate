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

## Failed / blocked
（まだ無し）

## Next step
ITERATION 4: TD-05 RuntimeRole.swift loopback 判定の特性化テスト（Swift。新規 or 既存テストファイルに追加、`Tests/UnitTests/`）。TD-09（loopback 集合統一）の安全網になる。post-gate は swift build + swift test を含む。
