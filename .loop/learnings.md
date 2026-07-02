# Loop learnings（共有: swift-test-green / ci-green。毎 run 開始時に contract より先に読む）

恒久ルール（再発失敗から1つずつ追記。クラスごと殺す予防を優先）:

- **LINE 無効時の send は「forward 契約」**: `lineEnabled=false` + adapter=`line` の send は reject ではなく remote openclawHost へ forward される（`BridgeCore.rejectLineOnClient` -> `forwardLineRequest`）。openclawHost が loopback だと 503 `line_forward_unavailable`。旧 403 `line_disabled` は廃止済（送信パスに該当コード無し）。
- **leak guard の personal パターン**: `scripts/security-leak-check.sh` は owner のホームパス（`/Users/<owner>`）や姓名パターン等を tracked ファイルから検出する。テスト/fixture の会話名・sessionKey には実名を使わず generic 名（例 `Alice Smith`）を使うこと。検査スクリプト側を緩めて通すのは禁止。
- **shellcheck はローカル未導入**: CI gate `shellcheck -S warning scripts/*.sh` を回すには `brew install shellcheck` が必要。未導入だと GATE2 は MISSING（coverage gap）。
- **shellcheck パースの罠（アポストロフィ）**: `${VAR:?message}` / `${VAR:-default}` の中にアポストロフィ（例 `owner's`）を書くと shellcheck が「シングルクォート開始」と誤認し、以降の行が SC1078/SC2154/SC1036 でカスケード誤検知する。`:?`/`:-` のメッセージにアポストロフィを入れない。
- **ffmpeg は `while read` ループ内で `-nostdin` 必須**（SC2095）: 付けないとループの stdin（リダイレクトしたファイル）を飲み込み、2件目以降の行が処理されない潜在バグになる。

## 観察待ちの仮説（確定したらルールへ昇格）
- **off-limits 設計は memory/ の P0 feedback 群も走査してから固める**（tech-debt-repay run 1, 2026-07-02）: loop contract の OFF-LIMITS を CLAUDE.md だけから作ったため、memory `feedback_pet_tracking_cdx_required.md`（PetModel tracking 系は Cdx 所有・CC 編集禁止）を見落とし、TD-11 で PetModel を CC 経路で編集してしまった（挙動不変・green だったが規律違反として Cdx レビューへ）。次の loop 設計時に再発しなければ DURABLE 昇格。
