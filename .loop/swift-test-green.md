# LOOP: swift test 全緑

GOAL: `swift test` を exit 0 / 全テスト pass / 0 failures にする。今 red の `BridgeCoreTests.testLineSendIsRejectedWhenLineDisabled`（:310 が `line_disabled`/403 を期待、実際は `line_forward_unavailable`/503）を**根本原因を理解した上で**緑にし、隠れた他の失敗も全て潰す。再利用可: 今後 suite が red になったらこのループを回す。

SUCCESS CRITERIA（strict, soft pass 無し）:
- `swift test`（full）が exit 0、全テスト pass、0 failures
- `testLineSendIsRejectedWhenLineDisabled` の緑化は、**code が正か test が正かを source/intent から判断した上で**行う。403/`line_disabled` が仕様なら code を直す。503/`line_forward_unavailable` が現仕様で正なら test 側の期待値を更新する。**どちらが正かを確かめずに assertion を現出力に合わせて書き換えない**（gate を gaming することになる）
- assertion を弱める / `XCTSkip` / test 削除 / `#if false` で緑にしていない
- LINE critical files（CLAUDE.md: `Adapters/LINE/*`, `Automation/AX/*`, `extensions/openclaw-plugin/src/*`）に触れた場合は最小変更のみ、無関係リファクタ無し
- diff の各行が「suite を緑にする」目標に trace できる（surgical）

VERIFY — the gate（実行する。self-grade 禁止）:
- `swift build`                                   # 最速: compile error をまず弾く
- `swift test --filter <修正中のテストクラス>`      # 速い: 対象だけ先に回す（例: BridgeCoreTests）
- `swift test`                                    # 最遅: full suite
PASS = full `swift test` が 0 failures / exit 0
- fastest -> slowest で回し、最初の red で止める（typecheck/build が赤いのに full suite を回さない）

STATE FILE: .loop/swift-test-green-state.md
- 開始前に必ず読む。これは restart ではなく resume。
- 各 iteration、追記する: 何をしたか / 何が pass・fail したか / 次の1手。

LEARNINGS FILE: .loop/learnings.md（毎回の run 開始時、contract より先に読む）
- 再発する失敗には恒久ルールを1つ書く（例: 「LINE 無効時の send は 503/line_forward_unavailable が正。403 期待の旧 test は stale」）。
- 単発の回帰ケースより、クラスごと殺す予防（lint / CLAUDE.md / AGENTS.md に畳む）を優先。

BUDGET（state に書く）: iteration cap 6 / no-progress streak 2 / wall-clock 30min。

EACH ITERATION:
1. contract（GOAL + SUCCESS CRITERIA + RULES）と state と learnings を**再読**してから、VERIFY を回して現在の失敗を見る。
2. 最もインパクトの大きい次の1手を PLAN する（ただ1つ）。
3. その1手を進める最小変更を EXECUTE する。
4. VERIFY（gate を回す）。結果を state に記録。
5. no-progress 回路ブレーカー: この iteration の各アクションを {tool 名 + 引数} で hash し直近窓と比較。同一アクション3回目、または plan/action が前 iteration と >85% 同一 -> stop_reason=no-progress。
6. DECIDE: SUCCESS CRITERIA を全て満たすか？
   - Yes -> "FINAL" を print して停止。
   - No  -> "ITERATING" を print して継続、最も弱い criterion から直す。

STOP WHEN（各停止に stop_reason をログ）:
- success         : full `swift test` が green（0 failures / exit 0）
- no-progress     : 2 iteration 連続で新規に直せたテストがゼロ、または同一アクション反復（回路ブレーカー）
- oscillation     : 同じ problem-fix のペアを 3 回繰り返した
- failure         : 1つのテストが 3 回試しても直らない
- budget          : iteration cap 6 / wall-clock 30min 到達
- scope-boundary  : off-limits 領域に触れる必要が出た / turn 上限超過
ON STOP: 何を変えたか / まだ何が落ちてるか / おおよその accept 率 を要約。

RULES:
- gate が実際に pass するまで done と言わない。self-grading 禁止。
- maker != checker: リスクのある修正（特に 403/503 のような期待値判断）は fresh eyes / sub-agent で再検証する。
- **No fake green**: assertion を弱める・`XCTSkip`・test 削除・`#if false`・機能の無断無効化 で緑にしない（CLAUDE.md P0: 機能の無断無効化・削除 絶対禁止）。
- Surgical changes only: diff の各行が GOAL に trace できること。隣接コードの美化・無関係リファクタ・quote/型/docstring の drive-by 変更 禁止。
- Search before assuming: 「無い」と言う前に grep する。再実装の前に既存を探す。
- LINE critical files を変更したら、その旨を state に明記（CLAUDE.md: test + 手動送受信確認が本来必要。ループ内では test まで、手動確認は人間にエスカレーション）。
- deploy はこのループでは**行わない**。反映が要る話は state に書いて人間に委ねる（deploy は post-task-restart.sh のみ、ループの責務外）。
- public repo: 実ホスト名・IP・個人名・トークンをコード/コメント/テストに混ぜない。
- commit するなら英語 conventional commits、Co-Authored-By 無し。1 サブステップ = 1 commit。
- Report compactly: PASS は1行。FAIL は {expected / actual / 直し方}。変わってない既出の失敗を再 print しない。
- Retry by failure class: 同じサブタスクが2回落ちたら、そのまま再試行せず最小フラグメント（1関数/1行/1テスト）に絞って試す。それも落ちたらエスカレーション。(retry -> decompose -> escalate)
- ループ中は質問しない。妥当な仮定を置き、state に記して継続する。
