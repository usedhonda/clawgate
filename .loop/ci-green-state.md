# Loop state — CI green（push 前ゲート）

## Budget
iteration cap 8 / no-progress 2 / wall-clock 40min

## Done
- iteration 1: pre-gate で leak guard が赤（outbound.test.js に owner の実名が混入）。generic 名にジェネリック化（177/280 行、commit 8fcc1a4）。
- iteration 1: shellcheck 導入（brew install shellcheck 0.11.0）。`ambient-enroll-self.sh` が赤 → `${:?}` 内アポストロフィ除去（カスケード誤検知の根本）+ 未使用 `rec` を `_` + ffmpeg `-nostdin`（潜在 stdin 食いバグも修正、commit 9ee58eb）。

## Failed / blocked
(なし)

## Result
SUCCESS — full ladder 全緑:
1 leak guard OK / 2 shellcheck OK / 3 JS syntax OK / 4 plugin tests 56/0 / 5 swift build OK / 6 swift test 227/0。
regression なし。accept 率 2/2。No fake green（検査スクリプトは緩めず実値を修正）。

## 環境メモ
- shellcheck はこの run で `brew install` 済（0.11.0）。次回 run では導入済みのはず。

## Next step
(完了。今後 push 前にこのループを回せば、CI 落ちを事前に潰せる)
