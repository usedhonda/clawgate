# .loop INDEX — このリポジトリの loop 一覧

| slug | goal | kind | gate | cap | runtime | 起動行 |
|------|------|------|------|-----|---------|--------|
| swift-test-green | `swift test` 全緑 | closed | `swift test` | 6 | self-paced | `/loop .loop/swift-test-green.md の手順に従って swift test を全緑に回して。state は .loop/swift-test-green-state.md、learnings は .loop/learnings.md。` |
| ci-green | CI gate 全緑（push 前ゲート） | closed | leak + shellcheck + JS + plugin + swift build/test | 8 | self-paced | `/loop .loop/ci-green.md の手順に従って CI を全緑に回して。state は .loop/ci-green-state.md、learnings は .loop/learnings.md。` |
| tech-debt-repay | 負債マップ構築→小さく安全な順に返済（LINE 危険域は提案のみ） | closed | ci-green と同じ6段ラダー（two-stage） | 12 | self-paced | `/loop .loop/tech-debt-repay.md の手順に従って技術的負債を返済して。state は .loop/tech-debt-repay-state.md、ledger は .loop/tech-debt-done.json、learnings は .loop/learnings.md。` |
| main-wip-integration | 現在の main WIP を保全し、論理単位へ分割して検証・commit | closed | focused per unit; final leak + build + full test + local restart | 6 | manual tick (Codex) | `.loop/main-wip-integration.md の手順に従って1 iterationだけ進めて。state は .loop/main-wip-integration-state.md を読んで更新して。完了なら FINAL、続行なら ITERATING で終えて。` |
| ui-responsiveness | 応答性A/B/C1/C2/Dの残件・相談・レビュー・安全な反映（Dは計測後採否） | closed | S1-S7: focused assertions + native操作計測 + 相談実返信 + 最終review + 安全なlocal反映 | 過去履歴保持。source保存済み、S4/S5計測・S7最終review残件 | 本人指示で直接実装再開。Goal自動再開/新規Goalなし | 既定回数だけで停止しない。現在の残件・証拠・継続条件はstate参照。 |
| minutes | 完成議事録の知識連携と選択音声による代替生成 | closed | C1-C8: owner契約・focused checks・永続read・native UI/実データ・正規反映 | 指定なし、実platform限度を維持 | Goal推奨 / 通常実行（未設定・未開始） | `.loop/minutes.md`、state `.loop/minutes-state.md`。同時起動不可。 |


共有: `.loop/learnings.md`（全 loop が参照する恒久ルール）。

方針（2026-06-25 決定）: loop は「push 前に手で回す closed」を正とする。見張り型(open)/cloud-cron は、御主人様の dev 機が常時起動でないため不採用。第3 loop は限界効用が薄く、必要になった具体目標が出たときに個別判断する。
