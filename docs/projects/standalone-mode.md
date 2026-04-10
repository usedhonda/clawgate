# Project: Standalone Mode — role/federation model の撤去

## Summary

ClawGate の外部依存を削減し、セットアップを **ClawGate + OpenClaw Gateway のみ** に簡素化する。

本質は「サーバーかクライアントか」ではなく **「LINE アプリを操作するかどうか」が唯一の分岐点**（ご主人様の指摘）。`nodeRole` / Federation / cc-status-bar の概念ごと撤去し、**capability ベース**に一本化する。

```
Before:  cc-status-bar ──→ ClawGate ──Federation──→ ClawGate(Host A) ←─poll── Gateway
After:   ClawGate (tmux直接監視) ←──────── direct poll/send ──────→ Gateway
```

## Architecture: Capability Model

### 設定の分岐軸（新）

| Capability | 意味 | 旧モデルでの対応 |
|---|---|---|
| **LINE adapter** | このマシンで LINE Desktop を操作するか | nodeRole=server |
| **Tmux monitor** | tmux セッションを監視するか | tmuxEnabled（変更なし） |
| **Gateway access** | リモート Gateway がこの ClawGate に接続するか | remoteAccessEnabled |

### 設定 UI（新 IA）

| セクション | 内容 |
|---|---|
| **LINE** | Enable LINE adapter (主スイッチ) → ON で conversation/poll/detection |
| **Tmux** | tmuxEnabled + session mode editor。source 表示は「Built-in tmux poller」固定 |
| **Gateway** | 「Allow Gateway to connect to this ClawGate」+ token + bind scope |
| **System** | launch at login / debug logging / utilities |

**削除するもの**: Node Role picker、Federation セクション、cc-status-bar URL

### ConfigStore キー整理

**削除（legacy read-only に降格）:**
- `nodeRole`
- `federationEnabled`, `federationURL`, `federationToken`, `federationReconnectMaxSeconds`
- `tmuxStatusBarURL`

**維持/昇格:**
- `lineEnabled`, `tmuxEnabled`, `remoteAccessEnabled`, `remoteAccessToken`
- LINE 詳細設定群（poll, detection, etc.）

**追加しないもの:**
- `gatewayMode` 等の新 enum は不要。`remoteAccessEnabled` の文言整理で足りる
- `nodeRole` を別の enum に置き換えない。**役割概念そのものを消す**

### Migration Policy

既存ユーザーの設定は capability flag を正本として自動移行:

1. `lineEnabled` → 既存値をそのまま維持
2. `tmuxEnabled` → 既存値を維持
3. `remoteAccessEnabled` → 既存値を維持
4. `remoteAccessToken` → 既存値を維持
5. `federationToken` → `remoteAccessToken` への fallback 吸収を一度実行
6. migrate 後は federation/nodeRole 系キーは read-only。新 save では書かない

**nodeRole を直訳で migration しない**。旧 role は proxy に過ぎず、capability flag が正本。

---

## Phases

### Phase A: Config Model + Startup Semantics（先行必須）

**設定 UI より先にやる。逆順だと UI だけ先に嘘をつく。**

| # | タスク | 担当 | 依存 |
|---|--------|------|------|
| A1 | `nodeRole` 参照箇所の棚卸し（`main.swift`, `BridgeCore`, doctor, health, menu wording） | CC | — |
| A2 | `SessionSnapshot` 共通型の設計 | CC | — |
| A3 | capability IA の最終決定（LINE / Tmux / Gateway / System） | CC | A1 |
| A4 | `AppConfig` legacy migration 実装 | Cdx | A3 |
| A5 | `TmuxDirectPoller` 実装 | Cdx | A2 |
| A6 | `CCStatusBarClient` → `SessionSnapshot` 共通型移行 | Cdx | A2 |
| A7 | `TmuxInboundWatcher` source-agnostic 化 | Cdx | A5, A6 |
| A8 | `main.swift` の role-gated 分岐を capability ベースへ移行 | Cdx | A4, A7 |
| A9 | doctor / health / BridgeCore の nodeRole 前提を capability に | Cdx | A8 |
| A10 | 起動時 source 選択ロジック（cc-status-bar 応答 → 使う、なし → direct poller） | CC | A7 |
| A11 | 統合テスト: cc-status-bar なし + federation なしで動作確認 | CC+Cdx | A9 |

### Phase B: Settings UI Rewrite

| # | タスク | 担当 | 依存 |
|---|--------|------|------|
| B1 | `SettingsView` の role 分岐を剥がす | Cdx | A8 |
| B2 | section を capability (LINE/Tmux/Gateway/System) で並べ直す | Cdx | B1 |
| B3 | 表示条件を `lineEnabled` 等 capability flag に寄せる | Cdx | B2 |
| B4 | 旧設定文言のクリーンアップ（「nodeRole=client...」等の残骸） | Cdx | B3 |
| B5 | README / docs の設定リファレンス更新 | CC | B4 |
| B6 | visual check + deploy | CC+Cdx | B5 |

### Phase C: Gateway Direct Poll (2B)

Phase A/B 安定後に着手。

| # | タスク | 担当 | 依存 |
|---|--------|------|------|
| C1 | ✅ Gateway poll target 切替設計 — コード変更不要。apiUrl + token で既に動く | CC | B6 |
| C2 | ✅ direct-access — remoteAccessEnabled + token が既存。hardening 不要 | — | C1 |
| C3 | ✅ health/doctor — Phase A9 で対応済み | Cdx | C2 |
| C4 | federation fallback の段階的除去（BridgeCore の send path）→ Phase D に延期 | Cdx | C3 |
| C5 | ✅ runbook 整備 — docs/runbooks/direct-gateway-setup.md 作成済み | CC | — |
| C6 | 統合テスト: Federation 無効で動作確認 | CC+Cdx | C5 |

### Phase D: 将来検討

- 2A（ClawGate → Gateway プッシュ）への移行検討
- Federation コード完全削除（Phase C で無効化が安定した後）

---

## リスク・注意事項

1. **session identity churn**: cc-status-bar は project/session ID を安定供給。direct poller で pane target ↔ project 名の対応が揺れると dedup 壊れる
2. **dual source duplicate**: cc-status-bar と direct poller の同時有効は禁止。起動時に1つ選ぶ
3. **remoteAccess security**: `0.0.0.0` 公開ではなく Tailscale/allowlist/token 前提
4. **nodeRole 残骸**: `main.swift` だけでなく `BridgeCore` / doctor / health / menu wording にも `nodeRole` 前提がある。A1 で先に棚卸し必須
5. **federation fallback 除去順**: direct poll/send が安定してから切る（Phase C4）

## 分担サマリー

| 担当 | 責務 |
|------|------|
| **CC** | 全体設計、capability IA 決定、migration policy、startup/doctor semantics 整理、docs/runbook |
| **Cdx** | config migration 実装、TmuxDirectPoller、source-agnostic 化、SettingsView rewrite、main.swift role→capability 移行、build/test |
