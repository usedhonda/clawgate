# .loop INDEX — このリポジトリの loop 一覧

| slug | goal | kind | gate | cap | runtime | 起動行 |
|------|------|------|------|-----|---------|--------|
| swift-test-green | `swift test` 全緑 | closed | `swift test` | 6 | self-paced | `/loop .loop/swift-test-green.md の手順に従って swift test を全緑に回して。state は .loop/swift-test-green-state.md、learnings は .loop/learnings.md。` |
| ci-green | CI gate 全緑（push 前ゲート） | closed | leak + shellcheck + JS + plugin + swift build/test | 8 | self-paced | `/loop .loop/ci-green.md の手順に従って CI を全緑に回して。state は .loop/ci-green-state.md、learnings は .loop/learnings.md。` |

共有: `.loop/learnings.md`（両 loop が参照する恒久ルール）。

方針（2026-06-25 決定）: loop は「push 前に手で回す closed」を正とする。見張り型(open)/cloud-cron は、御主人様の dev 機が常時起動でないため不採用。第3 loop は限界効用が薄く、必要になった具体目標が出たときに個別判断する。
