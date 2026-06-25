# Loop state — CI green（push 前ゲート）

## Budget
iteration cap 8 / no-progress 2 / wall-clock 40min

## Done
(まだ無し)

## Failed / blocked
(まだ無し)

## 既知の状態（run 開始時点）
- `swift test` は別ループ swift-test-green で全緑化済み（227 tests / 0 failures、commit afb5935）。pre-gate で再確認すること。
- `shellcheck` がローカル未導入の可能性あり。未導入なら `brew install shellcheck`、不能ならここに coverage gap として記録。

## Next step
pre-gate（ladder）を fastest -> slowest で1周回し、6 gate のどれが赤いかを確定する。最初に落ちた gate から潰す。
