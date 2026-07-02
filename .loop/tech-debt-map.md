# Tech-Debt Map（iteration 0, 2026-07-02）

3並列 read-only サーベイ（Swift Core / UI・Relay・Tmux / JS・scripts・docs）の統合。
判定凡例: **implement** = この loop で返済（ledger 参照）/ **escalated** = 提案のみ（`.loop/tech-debt-escalations.md`）/ **next-run** = 価値ありだが今回 cap 外。

テストカバレッジ基線（safety-net の根拠）:
- Swift: `BridgeCoreTests`(28) は send/context/doctor(line)/federation(health) を堅くカバー。ゼロ: `Federation/*`, `OpenClawWSClient.swift`(過去 P0 incident 持ち), `RuntimeRole.swift`, ambient HTTP wrapper, PetModel/MenuBarApp/PetWindow/PetBubbleView/TmuxAdapter/ClawGateRelay。
- JS: tests が import するのは client.js / outbound.js（+gateway helper）のみ。ゼロ: shared-state.js / context-cache.js / context-reader.js / project-view.js / config.js / directory.js。

## 今回返済する項目（ledger: .loop/tech-debt-done.json）

| id | phase | 内容 | 根拠 | 影響範囲 | リスク | 検証法 |
|----|-------|------|------|---------|--------|--------|
| TD-01 | verify | 6段 gate ladder がそのまま全緑で動くこと | it0 実測 | loop 全体の前提 | low | ladder 実行（済: leak/shellcheck/js/plugin56/build/test227 全緑） |
| TD-02 | safety-net | `shared-state.js` に特性化テスト（TTL map 3種: activeDispatchProjects 60s cleanup, sessionModeByProject, tprojOriginStore 10min TTL） | shared-state.js:21-23,122,145 | dev-lane 返信 + gate:direct origin routing（全 export を frozen gateway/outbound が消費） | low | 新規 `__tests__/shared-state.test.js`（set→get→expiry→eviction）green |
| TD-03 | safety-net | `context-cache.js` 純粋 helper にテスト（capText/filterPaneNoise/deduplicateTrailAgainst + 5min TTL） | context-cache.js:18,226,242,265 | gateway の context 組み立て（export 19個） | low | 新規テスト green |
| TD-04 | safety-net | `context-reader.js` にテスト（extractReferencedFiles/smartTruncate）。テストが import する形で「不要 export 疑惑」(191,236) も解消 | context-reader.js:191,236,292,321 | CLAUDE.md パース + context envelope | low | 新規テスト green |
| TD-05 | safety-net | `RuntimeRole.swift` loopback 判定の特性化テスト | RuntimeRole.swift:23 | role 解決 | low | 新規 Swift test green |
| TD-06 | cleanup | dead export 削除: `clearProgressSnapshot` / `getKnownProjects`（呼び出しゼロ、main が grep 再確認済み） | context-cache.js:184,380 | なし（参照ゼロ） | low | 削除後 plugin tests + js-check green |
| TD-07 | cleanup | `ISO8601DateFormatter()` ad-hoc 生成を共有 `Self.isoFormatter` に統一（main が :728/:1691 の混在を実測確認） | BridgeCore.swift:33 vs 728,1691,2470,2797 | timestamp 文字列のみ | low | swift test green（testLineHealthDebugReturnsSnapshotEnvelope が envelope を assert） |
| TD-08 | cleanup | ポートリテラル 18789/8765 を named constant に集約 | BridgeCore.swift:198,1508,1513,2164 / AppConfig.swift:71 / OpenClawWSClient.swift:582 / BridgeServer.swift:18 | doctor 表示・forward URL の将来drift 防止 | low | swift test green + doctor 文字列不変を確認 |
| TD-09 | cleanup | loopback ホスト集合の統一（BridgeCore は `::` 欠落、RuntimeRole と不一致）。TD-05 のテストを安全網に単一定義へ | BridgeCore.swift:2158 vs RuntimeRole.swift:23 | forward-target 判定 / role 解決 | mid | TD-05 テスト + swift test green。**挙動変更（`::` の扱い）が出る場合は escalate に切替** |
| TD-10 | separation | MenuBarApp のログ解析 pure helper（parseMessageFields/parseKeyValueMessage/shortProject/humanReadableSummary）を独立型へ抽出 + テスト | MenuBarApp.swift:1180,1234,1254,1268 | tmux.progress 等イベント文字列パース | low | 抽出後、新規テスト + swift test green |
| TD-11 | separation | PetModel の座標変換純関数（roughlySameFrame/appKitRectForTrackedFrame）を PetGeometry へ抽出 + テスト | PetModel.swift:562,611 | マルチディスプレイ Pet 配置 | low | 抽出後、新規テスト + swift test green |
| TD-12 | boundary | `~/.openclaw/openclaw.json` の手 parse 2箇所（BridgeCore.openclawInfo / OpenClawWSClient）を型付き reader に集約 = config 二系統の暗黙契約を明示化。着手前に `memory/reference_architecture.md` 読了必須 | BridgeCore.swift:183-200 / OpenClawWSClient.swift:582-583 | openclaw.json 読取全経路 | mid | characterization test 先行 + swift test green |

## escalated（提案のみ。詳細: .loop/tech-debt-escalations.md）

| id | 内容 | 根拠 | escalate 理由 |
|----|------|------|---------------|
| ES-01 | ClawGateRelay 退役（1433行 + Relay* 並行実装。実質デッド: 現行 deploy は起動せず、参照は防御 pkill と e2e 2本のみ） | Package.swift:13,35-42 / README.md:428 | 機能削除 P0 = ユーザー GO 必須 |
| ES-02 | ルート定義3重化の単一ソース化（table / if-else / federation switch） | BridgeRequestHandler.swift:19-56,116-262 / BridgeCore.swift:1710-1750 | routing characterization matrix が先。405/404 挙動 = 公開契約 |
| ES-03 | doctor() 246行の分解 | BridgeCore.swift:1453-1699 | /v1/doctor response shape は ops が消費 = 公開 API 扱い |
| ES-04 | send() 161行の関心分離（decode/forward/dispatch） | BridgeCore.swift:558-719 | コアホットパス大手術。testSend* 9本あるが今回 cap 外 → 提案書に段階案 |
| ES-05 | Safari-OAuth AX クラスタ（~250行 test ゼロ） | BridgeCore.swift:965-1075,2582-2714 | 挙動がコードから導出不能（AX live 検証必須）+ off-limits AX 隣接 |
| ES-06 | 「federation は vestigial」コメントと live code の矛盾 | BridgeCore.swift:1705-1707 vs main.swift:202 | federation の死活確定が先。コメントを信じて削除する事故防止 |
| ES-07 | `typingBusyStreakCount` write-only（dead telemetry か未完成 throttle） | BridgeCore.swift:40,695,658,698 | 意図がコードから判断できない |
| ES-08 | PetModel(1665行) god-object の全面分割 | PetModel.swift（10責務超） | スコープ大。TD-11 を足がかりに段階計画の承認が先 |
| ES-09 | MenuBarAppDelegate(1200行超) god-class の全面分割 | MenuBarApp.swift:12-1331 | 同上（TD-10 が第一歩） |
| ES-10 | PetBubbleView/PetWindow(950行級) の精査と分割 | PetBubbleView.swift / PetWindow.swift | AppKit 束縛濃く要追加調査 |
| ES-11 | テストが gateway.js の純関数を手写しコピー（false green リスク） | __tests__/send-telegram-tag.test.js:14-38 / line-ingress-noise-filter.test.js:12-134 | 本修正は frozen gateway.js の export 追加が必要 |
| ES-12 | release.env source ボイラープレート5箇所重複 | dev-deploy.sh:84 / restart-local-clawgate.sh:128 / macmini-local-sign-and-restart.sh:20 他 | 5箇所中3箇所が off-limits deploy chain |
| ES-13 | e2e script の stale な ClawGateRelay 参照 | scripts/federation-e2e.sh / host-a-host-b-e2e.sh | ES-01 と連動。盲目編集しない |
| ES-14 | Chrome manifest 冗長 permission（activeTab / 127.0.0.1 host 包含） | manifest.json:9,15 | 権限変更は拡張 reload + 実機 smoke 必須（loop 内で検証不能） |
| ES-15 | RetryPolicy / GenericInputSelectors の単一 caller 抽象の統合可否 | RetryPolicy.swift / GenericInputSelectors.swift | 削除・統合は設計判断（機能削除 P0） |

## next-run 候補（今回 cap 外、価値順）

- `OpenClawWSClient.swift`(585行) の特性化テスト — 過去 P0 protocol-mismatch incident 持ちの最優先ギャップ。TD-12 で openclaw.json 読取だけ先に固定
- TmuxOutputParser の抽出（TmuxOutputParserTests が既に安全網。テスト名と実体の乖離解消） — TmuxInboundWatcher.swift:869行
- TmuxAdapter(594行) の特性化テスト
- Ambient HTTP endpoints 10 handler の `AmbientEndpoints` 抽出（wrapper test 先行） — BridgeCore.swift:764-846
- `Federation/*` / TailscaleResolver / GatewayHealthMonitor / vibeterm-telemetry handler.js のテスト
- EventBus/AppLogger/FederationProtocol/OpsLogStore の ISO formatter 共有化（TD-07 の Core 横展開）
