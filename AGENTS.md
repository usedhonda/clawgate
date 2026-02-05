# AGENTS.md — AppBridge (Menu Bar UI Automation Bridge for macOS)

## 0. ゴール（このリポジトリで作るもの）
このプロジェクトは、macOS 上で動作する **メニューバー常駐アプリ**（以後 AppBridge）を作る。

AppBridge は以下を提供する：

- OpenClaw などのローカルエージェントからの要求を受け取る（IPC）
- **API が提供されていない macOS アプリ**を **Accessibility（AX）UI自動化**により操作して、要求を実行する
- 代表的な最初の対象として **LINE Macアプリ**の「送信」「受信検知（初期は1スレッド固定の簡易）」を実装する
- 将来は Slack / Discord / Teams / ブラウザ / その他アプリなど、複数アプリへ拡張できる設計にする（アダプタ方式）

本プロジェクトは「規約回避」「暗号化の破壊」「通信の盗聴」などは目的としない。
あくまで **ユーザー自身のMac上**で、ユーザーが許可した範囲で **UI操作を代行**するだけ。

---

## 1. 非ゴール（やらないこと）
- 外部公開サーバー化（インターネットに公開してリモート操作可能にする）はしない
- LINE の非公式ネットワーク解析、パケット改変、トークDB解析などはしない（UI自動化に限定）
- 複数マシン間同期、クラウド保存、アカウント管理などはしない
- 最初から「複数トーク完全監視」「未読バッジ完全追跡」など難度が高い機能は追わない（段階導入）

---

## 2. 主要ユースケース（MVP）
### 2.1 送信（必須）
- OpenClaw → AppBridge に「宛先」と「本文」を送る
- AppBridge が LINE を前面化（必要時）し、宛先トークを開き、本文を入力して送信する

MVPの宛先指定は次の優先度で実装：
1) `conversation_hint`（連絡先名/ルーム名の文字列）で検索欄から開く
2) 将来: `conversation_id` のような安定キー（ただしUI上で取れない場合は無理にやらない）

### 2.2 受信（MVPは簡易）
- LINE の特定トークを開きっぱなしにし、そのトークの最新メッセージを定期的に読み取り差分検知する
- 新着があれば AppBridge がイベントとして OpenClaw 側へ通知する

MVPでは「1トーク固定」を前提にしてよい（安定性優先）。

---

## 3. システム構成（推奨アーキテクチャ）
### 3.1 プロセス
- AppBridge 本体：メニューバーアプリ（Swift/SwiftUI + AppKit）
- 内部にローカルIPCサーバを持つ（localhost only）
- アプリ自動化は Accessibility API（AXUIElement）中心、必要時のみ CGEvent を併用

### 3.2 IPC（OpenClaw との接続）
最初の実装は **localhost の HTTP(JSON)** を推奨。理由：
- OpenClaw 側の実装言語に依存しない
- ログとデバッグが容易
- 後で WebSocket / SSE へ拡張しやすい

要件：
- `127.0.0.1` にのみ bind（外部から到達不可）
- 初期は固定ポート `8765`、将来は設定で変更可能
- ローカル認証：初期は `X-Bridge-Token` を必須にする（トークンはKeychain保存）

HTTP 実装方針：
- 依存を許すなら SwiftNIO を採用して軽量HTTPサーバ
- 依存を極力減らすなら、簡易TCP + JSON Lines の実装でも良い（ただし最初はHTTP推奨）

---

## 4. 外部仕様（IPC API）
### 4.1 ヘルス
- `GET /v1/health`
- Response: `{ "ok": true, "version": "0.1.0" }`

### 4.2 送信（汎用）
- `POST /v1/send`
- Headers: `X-Bridge-Token: <token>`
- Body:
```json
{
  "adapter": "line",
  "action": "send_message",
  "payload": {
    "conversation_hint": "自分メモ",
    "text": "hello from AppBridge",
    "enter_to_send": true
  }
}
```
- Response:
```json
{
  "ok": true,
  "result": {
    "adapter": "line",
    "action": "send_message",
    "message_id": "local-uuid",
    "timestamp": "2026-02-05T12:34:56+09:00"
  }
}
```

### 4.3 イベント購読（MVPはポーリングでもよい）
Option A（推奨）：SSE
- `GET /v1/events`（SSE）
- Headers: `X-Bridge-Token: <token>`
- Event例：
```json
{
  "type": "inbound_message",
  "adapter": "line",
  "payload": {
    "conversation_hint": "自分メモ",
    "text": "受信したメッセージ本文",
    "observed_at": "2026-02-05T12:35:10+09:00"
  }
}
```

Option B（最初に楽）：`GET /v1/poll?since=...` でポーリング
- ただし将来SSEへ移行できるよう、内部イベントキューは作っておく

---

## 5. コア設計（拡張性）
### 5.1 Adapter方式
`Adapter` プロトコルを定義し、アプリごとに実装する。

- `LINEAdapter`（MVP対象）
- 将来 `DiscordAdapter`, `TeamsAdapter`, `BrowserAdapter` 等

Adapterは「UI要素探索」「操作」「受信検知」を担当し、IPCや認証はBridge Coreが担当する。

### 5.2 UI自動化の抽象化
AX操作は壊れやすいので、共通層を用意する：

- `AXQuery`：AXツリー探索（role/title/description/identifier などでフィルタ）
- `AXActions`：setValue / press / focus / copy-paste / fallback key events
- `RetryPolicy`：再試行（指数バックオフ、上限回数、タイムアウト）
- `Stability`：LINEが最前面でない、ウィンドウが無い等の状態を整える

### 5.3 失敗設計（重要）
UI自動化は必ず失敗する。失敗を「観測可能」にすることが成功条件。

- すべての操作ステップは `StepLog` を残す（成功/失敗、所要時間、探索に使った条件）
- 失敗時は「どのAX要素が見つからなかったか」を報告する
- `AXDump`（デバッグ用）機能を実装：対象アプリのAXツリーを部分的にダンプしてログに出せる

---

## 6. macOS権限・動作条件
- AppBridge は **アクセシビリティ権限**が必須（ユーザーが許可すること）
- 送信を `press` で完結できるなら Input Monitoring は不要になり得る
  - ただし fallback で CGEvent 送信をする場合、追加権限が必要になる可能性あり
- 画面ロック中、ユーザーセッション非アクティブ時は動作が制限される可能性が高い
  - MVPは「ユーザーがログイン済み・LINE起動中・画面が生きている」前提でよい
  - 将来の改善として「失敗時に復旧案内」「要求のキューイング」は検討

---

## 7. リポジトリ構成（作るべきもの）
```
AppBridge/
  AppBridge.xcodeproj or AppBridge.xcworkspace
  AppBridge/
    UI/                       # Menu bar UI, settings
    Core/
      BridgeServer/           # HTTP server + auth + routing
      EventBus/               # inbound/outbound event queue
      Logging/
      Config/
      Security/               # Keychain wrapper
    Automation/
      AX/
        AXQuery.swift
        AXActions.swift
        AXDump.swift
      Retry/
    Adapters/
      AdapterProtocol.swift
      LINE/
        LINEAdapter.swift
        LineSelectors.swift    # AX探索用セレクタ群（後で更新しやすく分離）
  Tools/
    axdump/                    # 任意：CLIでAXダンプを取れるデバッグツール
  Tests/
    UnitTests/
    IntegrationNotes.md        # 手動テスト手順
  docs/
    architecture.md
    troubleshooting.md
```

---

## 8. LINE Adapter（MVPの具体要件）
### 8.1 送信フロー（推奨ステップ）
1) LINEが起動していなければ起動（NSWorkspace）
2) メインウィンドウ取得（AXWindows）
3) 検索欄を見つける（AXRole/Description/Title等で探索）
4) `conversation_hint` を入力し Enter（または候補クリック）
5) トーク画面に遷移したことを確認（ウィンドウ内の要素変化で判定）
6) 入力欄を見つけ、テキストをセット
7) 送信ボタン `press`、なければ Enter fallback
8) 送信成功の簡易判定：
   - 入力欄が空になった / 直前メッセージに送信した本文が見える、等（壊れやすいので弱判定でもOK）

### 8.2 受信（MVP簡易）
- 「現在開いているトーク」のメッセージ一覧を一定間隔で読む
- 最新要素のテキストを正規化して、前回と違えば新着としてイベント化
- 重複抑止：直近N件のハッシュをリングバッファで保持

### 8.3 セレクタ（壊れやすいので分離）
- AXRole / AXSubrole / AXTitle / AXDescription / AXIdentifier（取得できれば）を使う
- 文字列一致は完全一致より「contains」を基本に、複数候補からスコアリングする
- 取得できる属性が環境で違う可能性を前提にする

---

## 9. 品質要件
- すべての外部入力（HTTP body）はバリデーションする
- 例外/エラーは握りつぶさず、HTTPで構造化して返す
- ログは PII（会話本文）をデフォルトでは出さない（オプションで出せる）
- CPU負荷を抑える（受信監視はポーリング間隔を設定可能）
- 依存は最小限（採用するなら SwiftNIO 程度まで）

---

## 10. テスト方針
自動テストできる範囲とできない範囲を分ける。

- Unit tests:
  - ルーティング、認証、設定、イベントキュー、リトライ、重複抑止
- Manual / integration:
  - LINE UI操作は手動テスト手順をdocsに明文化
  - `AXDump` を使って「探索できること」を確認するチェックリストを作る

---

## 11. 段階的マイルストーン（必ずこの順で）
M0: プロジェクト作成（メニューバー表示、設定画面枠）
M1: BridgeServer（/health, token auth, /send をstubで返す）
M2: AXDump ツール（LINEのウィンドウツリーを出せる）
M3: LINEAdapter send_message（“現在開いているトークへ送る”）
M4: 宛先検索 → トーク移動 → 送信
M5: 受信検知（1トーク固定、差分検知でイベント発火）
M6: SSE/イベント配信（OpenClawに渡せる）
M7: 安定化（リトライ、タイムアウト、ログ改善、設定UI）

---

## 12. 実装ルール（Codexへの指示）
- まず M0〜M2 を最短で通し、AXツリーの「実データ」をログで観測できる状態にする
- 推測でセレクタを決めない。AXDump結果を元にセレクタを設計する
- 1つの機能を小さく作って動かし、ログを増やし、壊れたら復旧しやすくする
- 依存を増やす前に、標準APIでできるか検討する
- UI自動化は失敗する前提。失敗時の情報（どこまで進んだか）を必ず返す

---

## 13. Done の定義（MVP完了条件）
- メニューバー常駐として起動し、設定から token と基本設定を管理できる
- `GET /v1/health` が返る
- `POST /v1/send` で LINE の指定トークにメッセージを送れる（成功/失敗が判別できる）
- 受信検知（1トーク固定）が動き、イベントとして取り出せる（SSE or poll）
- 失敗時ログに AX探索の情報が残り、次に直す手がかりがある
