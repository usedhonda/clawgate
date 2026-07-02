# LOOP: 技術的負債の返済（マップ駆動 refactor）

GOAL: コードベースを深く読んで負債マップ `.loop/tech-debt-map.md`（根拠ファイル・影響範囲・リスク・検証法つき）を作り、その各項目を ledger 化して「小さく安全な順」に返済する。既存挙動は一切壊さない。実装できない項目（下記 escalate 条件）は提案書に落として escalate する。

SUCCESS CRITERIA（strict, soft pass 無し）:
- `.loop/tech-debt-map.md` が存在し、全項目に {根拠ファイル:行 / 影響範囲 / リスク(低・中・高) / 検証法} が揃っている。
- `.loop/tech-debt-done.json` の全項目が status ∈ {"pass", "escalated"}。"pass" は必ず実在の verified_by（gate 出力/コマンド）付き。
- 6段 gate ladder（下記 VERIFY）が全緑で、前緑だった check の回帰ゼロ。
- 不変条件を全て維持:
  - gateway.js の pendingQuestions stale guard（stale 単独で interaction_pending にしない）
  - LINE-disabled send = 503 `line_forward_unavailable` contract
  - 機能の無断無効化・削除ゼロ（値を0にする/flag false/コメントアウト全部禁止）
  - public repo 漏洩ゼロ（実ホスト名 `*.ts.net`・実IP `100.x`・個人名・Team ID・トークン）
- "escalated" 項目には `.loop/tech-debt-escalations.md` に提案書（何を・なぜ・どう検証するか・触るファイル）が揃っている。

ESCALATE 条件（実装せず提案に留める。ledger status="escalated"）:
- 仕様がコードから判断できない項目（正解が repo 内に無い）
- 公開 API 相当に触る項目: Bridge HTTP API `/v1/*` の response shape / status code、plugin の channel API 契約、`~/projects/openclaw/oc-general/docs/contracts/` が正本の契約面
- DB schema / 認証 / 課金に触る項目（該当が出た場合）
- OFF-LIMITS（下記 RULES）に触らないと返済できない項目

VERIFY — two-stage gate（実行する。self-grade 禁止。fastest -> slowest、最初の red で止める）:
ladder:
```
bash scripts/security-leak-check.sh --all
shellcheck -S warning scripts/*.sh
find extensions -name '*.js' -not -path '*__tests__*' -exec node --check {} +
node --experimental-test-module-mocks --test extensions/openclaw-plugin/src/__tests__/*.test.js
swift build
swift test
```
- pre-gate（iteration 開始時）: ladder 全走。**赤ならベースラインが壊れている -> HALT（stop_reason=poisoned-baseline）**。直前 iteration の post-gate 全緑直後から working tree が変わっていなければ（state の last_green と HEAD+dirty が一致）pre-gate は省略可。
- post-gate（変更後）: ladder 再走。**前緑の check が落ちたら FREEZE、commit しない**（stop_reason=regression）。
PASS = 6 gate 全 exit 0 かつ回帰なし。
- 重い swift build/test は、Swift に触っていない iteration では省略可。ただし各項目の "pass" 確定前と最終 FINAL 前は必ず full ladder を1回通す。

STATE FILE: .loop/tech-debt-repay-state.md
- 開始前に必ず読む。restart ではなく resume。
- 各 iteration、追記: 対象項目 id / 何をしたか / gate 結果 / 次の1手。

DONE LEDGER: .loop/tech-debt-done.json
```
[{ "id": "TD-01", "phase": "verify|safety-net|cleanup|separation|boundary",
   "title": "...", "evidence": "file:line", "impact": "...", "risk": "low|mid|high",
   "verify": "この項目の検証法", "status": "pending|pass|escalated|blocked",
   "verified_by": "gate 出力 / コマンド", "commit": "<sha>" }]
```
- status を "pass" にできるのは実在の verified_by がある時のみ。全項目が pass か escalated になった時だけ done。

LEARNINGS FILE: .loop/learnings.md（毎 run 開始時、contract より先に読む。既存 loop と共有）
- 再発する失敗は UNVERIFIED に1つ書き、2度目の確認で DURABLE へ昇格。learnings が SUCCESS CRITERIA / gate / stop 条件を書き換えることは禁止（人間の編集のみ）。

BUDGET（state に書く）: iteration cap 12 / no-progress streak 3 / wall-clock 120min。

ITERATION 0 — 負債マップ構築（1回だけ。コードは変更しない）:
1. 深読み: 巨大ファイル（BridgeCore.swift 2800行, PetModel.swift 1665行, ClawGateRelay/main.swift 1433行, MenuBarApp.swift 1331行, TmuxInboundWatcher.swift 869行 等）、重複ロジック、dead code、テストの薄い領域、設定二系統（UserDefaults vs openclaw.json）の暗黙結合、docs と実装の乖離を調査する。読み専の調査は Explore サブエージェント並列で可。
2. `.loop/tech-debt-map.md` に項目化: 各項目 {根拠ファイル:行 / 影響範囲 / リスク / 検証法 / 実施 or escalate 判定}。
3. ledger `.loop/tech-debt-done.json` に落とし、**この順序で並べる**（小さく安全な順）:
   - phase=verify: 検証コマンド確認（ladder 6 gate が全部そのまま動き全緑であること自体を最初の項目にする）
   - phase=safety-net: 安全網（返済対象で テストが薄い箇所へ characterization test を先に追加）
   - phase=cleanup: 安全な整理（dead code / 未使用 export / 重複定数 / 乖離 docs）
   - phase=separation: 責務分離（巨大ファイルからの責務抽出。挙動不変の移動のみ）
   - phase=boundary: 境界明確化（層・module 境界、暗黙契約の明示化）
4. LINE クリティカル群由来の負債・escalate 条件該当は最初から status="escalated" とし、提案書を escalations に書く。
5. map + ledger を `docs(loop):` で commit。ここまで実コード変更ゼロ。

EACH ITERATION（iteration 1 以降）:
1. contract（GOAL + SUCCESS CRITERIA + RULES）と state と learnings と ledger を**再読**し、pre-gate を確認。
2. ledger の pending 先頭（= 最も小さく安全な次の1項目）だけを PLAN。
3. その項目の最小変更を EXECUTE。挙動を変えない（refactor = 観測可能な挙動の同値変換のみ）。
4. Regression guard: separation / boundary の項目は、変更前にその挙動を固定する最小テストを Tests/UnitTests か plugin __tests__ に1本追加（safety-net 項目で既に足していれば不要）。1 fix + 1 guard を同一 commit。
5. post-gate（ladder）。結果を state と ledger（verified_by / commit）に記録。回帰なら FREEZE + revert。
6. commit: 英語 conventional commits（refactor:/test:/chore:/docs:）、1項目 = 1 commit、Co-Authored-By 無し。
7. no-progress 回路ブレーカー: 各アクションを {tool 名 + 引数} で hash。同一アクション3回目、または plan が前 iteration と >85% 同一 -> stop_reason=no-progress。
8. DECIDE: ledger 全項目が pass か escalated か？
   - Yes -> 独立完了チェック（下記）を通してから "FINAL" を print して停止。
   - No  -> "ITERATING" を print して次の pending へ。

独立完了チェック（maker != checker）: FINAL の前に、fresh な sub-agent に {ledger + 直近 diff + このファイルの SUCCESS CRITERIA} だけを渡し、「pass 項目が実際に検証されているか / escalated 項目に提案書が実在するか / 回帰やテスト弱体化が無いか」を独立確認させる。NG が返れば FINAL しない。

STOP WHEN（各停止に stop_reason をログ）:
- success            : 全項目 pass/escalated + full ladder 全緑 + 独立完了チェック PASS
- no-progress        : 3 iteration 連続で ledger が進まない、または同一アクション反復
- oscillation        : 同じ problem-fix ペアを3回繰り返した
- failure            : 1項目が3回試しても直らない -> その項目を "blocked" にして escalations へ、次項目に進む。escalate 先も無ければ停止
- regression         : post-gate で前緑の check が落ちた -> FREEZE、commit しない
- poisoned-baseline  : pre-gate が最初から赤
- budget             : cap 12 / wall-clock 120min 到達
- scope-boundary     : OFF-LIMITS に触れないと進めない -> 提案書化して escalate
- escalate           : dead-end を人間へ引き継いだ

ON DEAD-END（failure / budget / poisoned-baseline / scope-boundary）: 黙って死なない。`.loop/tech-debt-escalations.md` に {何を試した / 最後のエラー / どこで止まった / 提案する次の一手} を文脈込みで書いてから停止する。「人間へ引き継ぐ」は成功経路であって失敗ではない。

ON STOP: 何を返済した / 何を escalate した / まだ何が pending か / おおよその accept 率、を要約。**Swift か plugin に変更が及んだ場合は「deploy（./scripts/post-task-restart.sh）が別途必要」と最終報告に明記する（loop からは実行しない）。**

RULES:
- OFF-LIMITS（編集絶対禁止。必要なら escalate）:
  - LINE クリティカル群: `ClawGate/Adapters/LINE/LINEAdapter.swift`, `LINEInboundWatcher.swift`, `LineSelectors.swift`, `Detection/*.swift`, `ClawGate/Automation/AX/AXActions.swift`, `AXQuery.swift`, `extensions/openclaw-plugin/src/outbound.js`, `gateway.js`, `client.js`, `channel.js`
  - vendored: `extensions/clawgate-chrome/vendor/ocrad.js`
  - `scripts/legacy/`（退役済み、参照のみ）
  - deploy 系: `scripts/post-task-restart.sh` とその internal 呼出しスクリプト群
  - `.local/`, `.env*`, secrets, `prompts-local.js`（stage も禁止）
- gate が実際に pass するまで done と言わない。self-grading 禁止。
- 初回 pre-gate が全緑でも「負債ゼロ」ではない — この loop の成果物は map + 返済。ただし map を作った結果、実返済に値する項目がゼロなら、それを正直に FINAL として報告する（仕事をでっち上げない）。
- No fake done: assertion 弱体化・XCTSkip・test 削除・`#if false`・leak-check のパターン緩和で緑にしない。placeholder / stub を完了と報告しない。
- Surgical changes only: diff の各行が「その ledger 項目」に trace できること。項目外の drive-by refactor（quote/整形/import 並べ替え/ついで修正）禁止。
- Search before assuming: 「無い」と言う前に grep。再実装の前に既存を探す。
- refactor 中に bug を見つけたら: 直さず ledger に新項目（または escalation）として記録。挙動変更と構造変更を同一 commit に混ぜない。
- `Core/Federation/`, `Core/BridgeServer/`, `Core/Config/`, `Core/OpenClaw/`, `extensions/openclaw-plugin/` に触る項目の前に `memory/reference_architecture.md` を読む。乖離を見つけたら doc 更新も同項目に含める。
- Report compactly: PASS は1行。FAIL は {項目 id / expected / actual / 直し方}。既出の変わらない失敗を再 print しない。
- Retry by failure class: tool 未導入 -> 導入を試し不能なら surface。transient -> 1-2回再試行。validation fail -> feedback から書き直す。同一項目2回失敗 -> 最小フラグメント（1関数/1テスト）に絞る -> それも落ちたら blocked + escalate。
- ループ中は質問しない。妥当な仮定を置き、state に記して継続する。ただし仮定が「仕様の推測」になる項目は実装せず escalate（ESCALATE 条件1）。
