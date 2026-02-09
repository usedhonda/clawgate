# TmuxAdapter 実装

## 日時
2026-02-09 01:46

## 指示
LINE 経由で Claude Code (tmux) にタスクを委任し、完了時に LINE に報告する TmuxAdapter の実装

## ブランチ
`feat/tmux-adapter`

## 新規ファイル

### ClawGate/Adapters/Tmux/TmuxShell.swift
- tmux CLI ラッパー (Process ベース)
- `sendKeys(target:text:enter:)` — literal text 送信 + Enter
- `capturePane(target:lines:)` — pane 出力キャプチャ
- `listSessions()` — セッション一覧

### ClawGate/Adapters/Tmux/CCStatusBarClient.swift
- cc-status-bar WebSocket クライアント (URLSessionWebSocketTask)
- セッション追跡: sessions.list, session.updated, session.added, session.removed
- 自動再接続 (3s * attempt, 最大20回)
- `onStateChange` / `onSessionsChanged` コールバック

### ClawGate/Adapters/Tmux/TmuxAdapter.swift
- AdapterProtocol 実装
- sendMessage: project 解決 -> allowed チェック -> status 確認 -> TmuxShell.sendKeys
- getContext / getMessages / getConversations 実装

### ClawGate/Adapters/Tmux/TmuxInboundWatcher.swift
- running -> waitingInput 遷移を検出
- TmuxShell.capturePane で出力キャプチャ
- EventBus に inbound_message (adapter=tmux, source=completion) イベント発行

## 変更ファイル

### ClawGate/Core/Config/AppConfig.swift
- tmuxEnabled, tmuxStatusBarUrl, tmuxAllowedSessions 追加
- ConfigStore の load/save に tmux セクション追加

### ClawGate/Core/BridgeServer/BridgeModels.swift
- ConfigTmuxSection 追加
- ConfigResult に tmux フィールド追加

### ClawGate/Core/BridgeServer/BridgeCore.swift
- config() に tmux セクション追加

### ClawGate/UI/SettingsView.swift
- Tmux セクション (Enabled toggle, Status Bar URL)

### ClawGate/UI/MenuBarApp.swift
- "Claude Code Sessions" サブメニュー (チェックボックス付き)
- refreshSessionsMenu() — セッション一覧の動的更新
- toggleSession() — allowed sessions の toggle + 永続化

### ClawGate/main.swift
- CCStatusBarClient, TmuxAdapter, TmuxInboundWatcher の初期化
- AdapterRegistry に tmuxAdapter 登録
- tmuxEnabled 時に startTmuxSubsystem() 呼び出し
- menuBarDelegate への参照追加

### extensions/openclaw-plugin/src/client.js
- clawgateTmuxSend, clawgateTmuxContext, clawgateTmuxConversations 追加

### extensions/openclaw-plugin/src/gateway.js
- handleTmuxCompletion() — tmux 完了イベント処理
- poll ループで adapter=tmux, source=completion イベントをハンドル

## 検証結果
- swift build: 成功 (warning 0)
- dev-deploy.sh: S1-S4 PASS, S5 は gateway 再起動タイミングの遅延
- OpenClaw gateway: doctor OK (5/5) + initial cursor=0 確認
- /v1/config: tmux セクション正常表示
- /v1/conversations?adapter=tmux: 正常応答 (sessions: 0, WebSocket 未接続のため)

## アーキテクチャ
```
LINE user -> OpenClaw AI -> ClawGate POST /v1/send adapter=tmux
                                    -> TmuxAdapter -> TmuxShell.sendKeys
                                                   -> Claude Code (tmux pane)
                                                   -> cc-status-bar WS
                                                   -> TmuxInboundWatcher (completion)
                                                   -> EventBus
                                    -> OpenClaw poll -> handleTmuxCompletion
                                                     -> AI summarize -> LINE reply
```
