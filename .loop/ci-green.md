# LOOP: CI green（push 前ゲート）

GOAL: `.github/workflows/ci.yml` がローカルで通る状態にする。CI が回す全 gate（leak guard / shellcheck / JS 構文 / plugin tests / swift build / swift test）をローカルで全緑にし、push 前に CI 落ちを潰す。

SUCCESS CRITERIA（strict, soft pass 無し）:
- 以下6 gate が全て exit 0:
  1. `bash scripts/security-leak-check.sh --all`（tracked ファイルに漏洩ゼロ）
  2. `shellcheck -S warning scripts/*.sh`（warning 以上ゼロ。未インストールなら `brew install shellcheck` で導入。導入不能なら state に明記してスキップ＝coverage gap として申告）
  3. `find extensions -name '*.js' -not -path '*__tests__*' -exec node --check {} +`（JS 構文エラーゼロ）
  4. `node --experimental-test-module-mocks --test extensions/openclaw-plugin/src/__tests__/*.test.js`（plugin tests green）
  5. `swift build`（compile 成功）
  6. `swift test`（0 failures / exit 0）
- 修正は**根本原因ベース**。assertion / check を弱める・skip・削除して緑にしない（Goodhart 防御）。
- public repo にビルド: 実ホスト名（`*.ts.net`）・実 IP（`100.x` 等）・個人名・Team ID・トークンをコード/コメント/テストに入れない（security-leak の本旨）。
- LINE critical files に触れた場合は最小変更（CLAUDE.md 記載パス）。deploy はループ責務外。機能の無断無効化禁止。
- diff の各行が「CI を緑にする」目標に trace できる（surgical）。

VERIFY — two-stage gate（実行する。self-grade 禁止。fastest -> slowest、最初の red で止める）:
ladder（この順で回す。軽いものから）:
```
bash scripts/security-leak-check.sh --all
shellcheck -S warning scripts/*.sh
find extensions -name '*.js' -not -path '*__tests__*' -exec node --check {} +
node --experimental-test-module-mocks --test extensions/openclaw-plugin/src/__tests__/*.test.js
swift build
swift test
```
- pre-gate（iteration 開始）: ladder を回して現状の赤を把握。**全緑なら done**（stop_reason=success）。
- post-gate（修正後）: ladder を再走。**前まで緑だった check が赤くなったら regression -> FREEZE, commit しない**（stop_reason=regression）。
PASS = 6 gate 全て exit 0 かつ regression なし。

STATE FILE: .loop/ci-green-state.md
- 開始前に必ず読む。restart ではなく resume。
- 各 iteration、追記: 何をしたか / どの gate が pass・fail したか / 次の1手。

LEARNINGS FILE: .loop/learnings.md（毎 run 開始時、contract より先に読む。swift-test-green と共有）
- 再発する失敗には恒久ルールを1つ書く。クラスごと殺す予防（lint / CLAUDE.md / AGENTS.md に畳む）を優先。

BUDGET（state に書く）: iteration cap 8 / no-progress streak 2 / wall-clock 40min。

EACH ITERATION:
1. contract（GOAL + SUCCESS CRITERIA + RULES）と state と learnings を**再読**し、pre-gate（ladder）を回して現在の赤を見る。
2. 最もインパクトの大きい次の1手を PLAN（ただ1つ。最初に落ちた gate から）。
3. その1手を進める最小変更を EXECUTE。
4. post-gate（ladder 再走）。結果を state に記録。regression が出たら FREEZE。
5. no-progress 回路ブレーカー: 各アクションを {tool 名 + 引数} で hash し直近窓と比較。同一アクション3回目、または plan/action が前 iteration と >85% 同一 -> stop_reason=no-progress。
6. DECIDE: 6 gate 全て緑 + regression なし か？
   - Yes -> "FINAL" を print して停止。
   - No  -> "ITERATING" を print して継続、最初に落ちてる gate から直す。

STOP WHEN（各停止に stop_reason をログ）:
- success           : ladder 6 gate 全緑（exit 0）
- no-progress       : 2 iteration 連続で新規に直せた gate ゼロ、または同一アクション反復
- oscillation       : 同じ problem-fix ペアを 3 回繰り返した
- failure           : 1つの gate が 3 回試しても直らない
- regression        : post-gate で前緑の check が落ちた -> FREEZE, commit しない
- budget            : iteration cap 8 / wall-clock 40min 到達
- scope-boundary    : off-limits 領域に触れる必要が出た / turn 上限超過
ON STOP: 何を変えたか / まだ何が落ちてるか / おおよその accept 率 を要約。

RULES:
- gate が実際に pass するまで done と言わない。self-grading 禁止。
- maker != checker: リスクのある修正は fresh eyes / sub-agent で再検証する。
- **No fake green**: assertion / check を弱める・XCTSkip・test 削除・`#if false`・機能の無断無効化・security-leak の検査パターンを緩める、で緑にしない（CLAUDE.md P0）。
- security-leak が赤いとき: 漏れた実値を**削除/ジェネリック化**して直す（`my-host.example-tailnet.ts.net` 等）。検査スクリプト側を緩めて通すのは禁止。
- shellcheck が赤いとき: 指摘された箇所を直す。`# shellcheck disable=` での握り潰しは、正当な理由を1行コメントで添える時のみ。
- Surgical changes only: diff の各行が GOAL に trace。drive-by refactor（quote/型/整形/import 並べ替え）禁止。
- Search before assuming: 「無い」と言う前に grep。再実装の前に既存を探す。
- LINE critical files を変更したら state に明記（test まで。手動送受信確認は人間にエスカレーション）。
- deploy はこのループでは行わない（post-task-restart.sh のみ、責務外）。
- commit するなら英語 conventional commits、Co-Authored-By 無し。1 サブステップ = 1 commit。1 fix + その gate の緑化を 1 commit。
- Report compactly: PASS は1行。FAIL は {gate 名 / expected / actual / 直し方}。変わってない既出の失敗を再 print しない。
- Re-verify the diff, not the world: iteration 1 は全 ladder、以降は直した gate 周辺を中心に再走（swift build/test は重いので、JS/shell/leak だけ直した iteration は swift を毎回フル再走しなくてよい。ただし最終 done 判定の前に必ず full ladder を1回通す）。
- Retry by failure class: tool 未導入（shellcheck/node 無し）-> 導入を試し、不能なら surface（burn しない）。transient -> 1-2 回再試行。validation fail -> feedback から書き直す（盲目再試行しない）。
- Shrink the unit on repeat failure: 同じ gate が2回落ちたら最小フラグメント（1ファイル/1テスト/1行）に絞る。それも落ちたらエスカレーション。(retry -> decompose -> escalate)
- ループ中は質問しない。妥当な仮定を置き、state に記して継続する。
