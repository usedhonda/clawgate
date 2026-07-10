@AGENTS.md

## 🚨 Deploy ルール 絶対遵守 (P0)

**deploy = `./scripts/post-task-restart.sh` 単一 entry point のみ。**

- 実装完了したら確認求めず `post-task-restart.sh` 自動実行
- 個別 script (`restart-local-clawgate.sh`、`macmini-local-sign-and-restart.sh` 等) を直接叩くのは `post-task-restart.sh` の internal 呼出しのみ。CC が手動で打つのは禁止

## OpenClaw 契約 hub

OpenClaw エコシステムの公開 contract は `~/projects/openclaw/oc-general/docs/contracts/` を正本とする。channel routing / event 配信 / WS RPC を触る前に必ず該当 contract を確認すること（特に `event-contract.md`, `runbooks/delivery-routing.md`, `runbooks/clawgate-channel-routing.md`, `ws-event-contract.md`）。

## LINE Critical Files (変更時は必ず動作確認)

以下のファイルは LINE 送受信の根幹。変更時は `swift test` + 手動送受信確認を実行すること。

**Swift (送受信コア)**:
- `ClawGate/Adapters/LINE/LINEAdapter.swift`
- `ClawGate/Adapters/LINE/LINEInboundWatcher.swift`
- `ClawGate/Adapters/LINE/LineSelectors.swift`
- `ClawGate/Adapters/LINE/Detection/*.swift`
- `ClawGate/Automation/AX/AXActions.swift`
- `ClawGate/Automation/AX/AXQuery.swift`

**JS (OpenClaw プラグイン)**:
- `extensions/openclaw-plugin/src/outbound.js`
- `extensions/openclaw-plugin/src/gateway.js`
- `extensions/openclaw-plugin/src/client.js`
- `extensions/openclaw-plugin/src/channel.js`

変更を最小限に留め、無関係なリファクタを同時にやらない。

## Gateway Autonomous Pipeline (変更時は自己ループ回帰に注意)

`gateway.js` の autonomous 処理パイプラインを変更する場合、以下の不変条件を壊さないこと:

**不変条件: `pendingQuestions` の stale エントリが autonomous suppress を永続化してはならない**

- `detectInteractionPendingFromCompletion` は `pendingQuestions` Map を参照するが、stale エントリ (10min超) 単独では interaction_pending と判定しない
- current evidence (`waitingReason` or `parsedHasOptions`) がない stale pending は delete する
- この条件が壊れると、1回の question イベントで以降の全 completion が永久に suppress される自己ループが発生する (2026-03-13 incident)

**変更時の確認**: `pendingQuestions` の書き込み・読み取り・削除パスを変更する場合は、「question 解消後 10 分以上経った completion が suppress されないこと」を Gateway ログで確認すること。

## 機能の無断無効化・削除 絶対禁止 — P0

**動いている機能を、ユーザーの明示的指示なしに無効化・削除・revert することは絶対禁止。**

- 値を 0 にして無効化、フラグを false にして停止、コードをコメントアウト — すべて禁止
- 「不安定だから一旦無効化」「設計し直すから止める」は CC/Cdx の独断では許されない
- バグがあっても、機能を消すのではなく**修正する**。修正できないなら**ユーザーに報告して判断を待つ**
- 「動いている」を壊すな。戻せない状態を作るな

**教訓** (2026-04-09): hide 機能を CC が「設計が足りない」と判断して勝手に `hideAfterMinutes=0` で無効化。ユーザーが30秒待っても何も起きず、信頼毀損。

## 作業の中断・終了を提案しない — P0

**「今日はここまで」「一旦止めよう」「次のセッションで」等、作業の中断・終了・延期を CC から提案してはならない。**

- うまくいかなくても、切り上げるのはユーザーが決めること
- CC がやるべきは「止める提案」ではなく「次の一手を考えて実行する」
- 困ったら Cdx に聞く、設計を見直す、別のアプローチを試す — 手を止めない

**教訓** (2026-04-09): hide 機能がうまくいかず「今夜は一旦ここで止めた方がいいかもしれない」と提案。グローバル CLAUDE.md P0「セッション終了の提案禁止」に違反。

## 正解があるなら推測より先に正解を見ろ — P1

**正解が存在するなら、推測で進めない。まず正解を確認し、それに合わせる。**

## アーキテクチャ理解義務 — P1

**セッション開始時に `memory/reference_architecture.md` を読んでから作業開始する。**

- ClawGate はサーバー (macmini) とクライアント (この Mac) の2台構成。同じ .app が異なる役割で動く
- 設定は UserDefaults (Settings UI) と openclaw.json (Gateway 生成) の2系統ある
- 接続・設定・bridge・manifest を変更する場合は、**設定画面を確認し、既存の接続経路を理解してから**変更する
- 変更後は reference_architecture.md が現状と合っているか確認し、乖離があれば更新する
- 完了報告に `Arch doc: current / updated / N/A` を含める

**更新トリガー対象パス**:
`Core/Federation/`, `Core/BridgeServer/`, `Core/Config/`, `Core/OpenClaw/`, `extensions/openclaw-plugin/`, `extensions/clawgate-chrome/manifest.json`

**教訓** (2026-04-12): WS 接続先が `ws://127.0.0.1` 固定だったのに、Settings UI の Host 設定を確認せず SSH トンネルやサーバー再起動で遠回りした。設定画面を見れば一発だった。

## Remote Host 操作ルール — P0

1. **正規スクリプトのみ使う**: 手動 codesign、手動 openssl、ad-hoc 署名 (`-s -`) は全て禁止
2. **失敗したら即停止**: 代替手段を試さない。ユーザーに報告して判断を待つ
3. **署名 identity を変えない**: 正規 cert 以外で署名すると Accessibility/Screen Recording が剥がれる
4. **memory/deployment.md を事前に読む**: remote host 操作の前に必ず確認
5. **パスワードを memory/docs に固定値で保存しない**: stale 化して事故の原因になる

## Public Repository — 個人情報・インフラ情報の混入禁止

このリポジトリは **パブリック**。以下をコード・コメント・ドキュメントに含めないこと:

- **実ホスト名**: Tailscale hostname (`*.ts.net`), macOS hostname, SSH alias
- **実 IP アドレス**: Tailscale CGNAT (`100.x.x.x`), プライベート IP
- **ネットワーク ID**: Tailscale tailnet ID, DERP relay 名
- **個人名・アカウント名**: ユーザー名, Apple ID, GitHub handle (README の `<owner>` は意図的)
- **トークン・シークレット**: API キー, Bearer トークン, パスワード (当然)

**コメント内の例示にも適用**。`host` コマンドの出力例などは `my-host.example-tailnet.ts.net` のようにジェネリック化する。

**既存の安全策**: `.gitignore` で `.local/`, `.env*`, `prompts-local.js`, `CLAUDE.md` 等を除外済み。`scripts/security-leak-check.sh` が CI で実行される。
