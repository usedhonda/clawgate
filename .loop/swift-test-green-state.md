# Loop state — swift test 全緑

## Budget
iteration cap 6 / no-progress 2 / wall-clock 30min

## Done
(まだ無し)

## Failed / blocked
(まだ無し)

## Known red（run 開始時点）
- `BridgeCoreTests.testLineSendIsRejectedWhenLineDisabled`（:310）: `line_disabled`/403 を期待、実際は `line_forward_unavailable`/503。期待値 drift。**code が正か test が正かを source/intent から判断してから直すこと**（assertion を 503 に雑に書き換えない）。

## Next step
`swift build` -> `swift test --filter BridgeCoreTests` で対象を再現し、`/v1/...` の LINE-disabled 送信が 503/line_forward_unavailable を返す経路を BridgeCore.swift で読んで、403/line_disabled から 503 へ変わったのが意図的か regression かを確定する。
