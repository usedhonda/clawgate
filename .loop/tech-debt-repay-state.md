# Loop state — 技術的負債の返済

## Budget
iteration cap 12 / no-progress streak 3 / wall-clock 120min

## Done
- [it0] pre-gate 6段ラダー全緑（leak pass / shellcheck 0 / js-check 0 / plugin 56 tests fail0 / swift build 25.7s / swift test 227 pass, 1 skipped, 0 fail）。baseline 健全 = poisoned-baseline なし。TD-01 = pass。
- [it0] 負債マップ完成: Explore 3並列（Core / UI・Relay・Tmux / JS・scripts・docs）→ `.loop/tech-debt-map.md` に統合。ledger 27項目（TD 12 = 今回返済、ES 15 = escalated 提案済 `.loop/tech-debt-escalations.md`）。main が一次ソース spot-check 2件実施（dead export 参照ゼロ / ISO formatter 混在を実測確認）= 委任成果の鵜呑みなし。実コード変更ゼロ。

## Failed / blocked
（まだ無し）

## Next step
ITERATION 1: TD-02 shared-state.js 特性化テスト（`__tests__/shared-state.test.js` 新規: activeDispatchProjects 60s cleanup / sessionModeByProject / tprojOriginStore 10min TTL の set→get→expiry→eviction）。frozen ファイルには触らない。post-gate は plugin tests + js-check（Swift 非接触なら swift 省略可、ただし TD 確定前に full ladder）。
