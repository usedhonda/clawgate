# ClawGate + OpenClaw 統合ガイド

ClawGateは、macOSのAccessibility APIを通じてLINEを自動操作するメニューバーアプリです。OpenClawと組み合わせることで、自然言語でLINEメッセージの送受信が可能になります。

---

## 60秒クイックスタート

### 1. インストール

**Homebrew (推奨)**
```bash
brew tap usedhonda/clawgate
brew install --cask clawgate
```

**DMG (手動)**
1. [Releases](https://github.com/usedhonda/clawgate/releases) から最新のDMGをダウンロード
2. ClawGate.appをApplicationsにドラッグ

### 2. 初回セットアップ

1. ClawGateを起動（メニューバーに🦀アイコンが表示）
2. 「Accessibility権限を許可」のダイアログで「システム設定を開く」をクリック
3. **System Settings > Privacy & Security > Accessibility** でClawGateをON
4. メニューバーの🦀をクリック → 「ペアリングコード」をコピー
5. OpenClawに入力して完了

### 3. 動作確認

OpenClawに以下を入力:

```
ClawGateのstatusを確認して
```

---

## プロンプト例（コピペで動く）

### LINEでメッセージを送る

```
ClawGateを使って、LINEの"田中太郎"に"お疲れ様です"と送って
```

### 現在のチャットを確認

```
ClawGateでLINEの現在開いているチャットの最新メッセージを読んで
```

### 会話一覧を取得

```
ClawGateでLINEのサイドバーに表示されている会話一覧を教えて
```

### トラブル時

```
ClawGateのDoctor機能を実行して、問題を診断して
```

---

## API概要

| エンドポイント | 用途 |
|----------------|------|
| `GET /v1/health` | 動作確認（認証不要） |
| `POST /v1/pair/request` | ペアリングコードでトークン取得（認証不要） |
| `GET /v1/doctor` | 自己診断レポート |
| `POST /v1/send` | メッセージ送信 |
| `GET /v1/context` | 現在の会話コンテキスト |
| `GET /v1/messages` | 表示中メッセージ一覧 |
| `GET /v1/conversations` | サイドバー会話一覧 |
| `GET /v1/events` | SSEイベントストリーム |

すべてのエンドポイント（health, pair/request除く）は `X-Bridge-Token` ヘッダーが必要です。

---

## 制約と回避策

| 制約 | 理由 | 回避策 |
|------|------|--------|
| LINEは前面化が必要 | Qt/AXの仕様制限 | ClawGateが自動で前面化（設定でON/OFF可） |
| 送信はEnterキー | LINEにAX送信ボタンがない | `enter_to_send: true`（デフォルト） |
| 検索欄経由でのみ会話遷移 | 直接conversation_id指定不可 | `conversation_hint`で名前検索 |
| バックグラウンド時は読取不可 | Qt kAXWindowsAttributeの制限 | LINEを前面に出す必要あり |

---

## セキュリティ

| 項目 | 説明 |
|------|------|
| **通信** | 127.0.0.1のみ（外部通信なし） |
| **トークン保存** | macOS Keychainに暗号化保存 |
| **ログ** | 会話内容はデフォルトで記録しない |
| **権限** | Accessibilityのみ使用 |

詳細は [local-only-manifest.json](./local-only-manifest.json) を参照。

---

## トラブルシューティング決定木

```
動かない
├── ClawGateは起動してる？
│   └── メニューバーに🦀がない
│       └── `open -a ClawGate` で起動
│
├── 権限は許可してる？
│   └── System Settings > Privacy & Security > Accessibility
│       └── ClawGateがOFFになっている → ONにする
│
├── LINEは起動してる？
│   └── LINEが起動していない
│       └── LINEを起動
│
├── LINEウィンドウは前面にある？
│   └── バックグラウンドにある
│       └── LINEを前面に表示
│
├── ポートは使用可能？
│   └── `lsof -i :8765` で確認
│       └── 他プロセスが使用中 → 終了させる
│
├── トークンは一致してる？
│   └── X-Bridge-Tokenが正しいか確認
│       └── メニューバー → 「トークンをコピー」
│
└── それでもダメ
    └── `/v1/axdump` でAXツリーを確認
        └── 予期しない構造の場合はissueを作成
```

---

## よくあるエラー

| エラーコード | 原因 | 対処 |
|--------------|------|------|
| `unauthorized` | トークン不一致 | 正しいトークンをヘッダーに設定 |
| `ax_permission_missing` | Accessibility権限なし | システム設定で許可 |
| `line_not_running` | LINEが起動していない | LINEを起動 |
| `line_window_missing` | LINEウィンドウが取得できない | LINEを前面に表示 |
| `message_input_not_found` | 入力欄が見つからない | チャット画面を開く |

---

## 関連ドキュメント

- [アーキテクチャ](./architecture.md)
- [トラブルシューティング詳細](./troubleshooting.md)
