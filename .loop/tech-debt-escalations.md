# Tech-Debt Escalations（提案のみ・実装は御主人様 GO 待ち）

> **RUN 2（2026-07-02）で 15件全て決着済み**。各項目の結末は `.loop/tech-debt-done.json` の verified_by を正とする。本ファイルは提案の原文 + 下記の「将来 GO 項目」を保持する。

## 将来 GO 項目（run2 で発見、未着手）
- **gateway.js `_filterDisplayName` setter export**: noise-filter テストの inline copy 残り5関数を本物 import 化するのに必要。frozen ファイルへの新規 API 面のため個別 GO 要（ES-11 部分解決の残り）
- **federation switch の routes 統合**: ES-02 で project-context-read のハンドラ分岐（HTTP=projectContextRead vs federation=runLocalProjectContextRead 直呼び）という実挙動差を発見したため統合を見送り、subset-guard テストで機械検知化。真の統合はこの分岐の意図確定が先
- **federation 経由で到達不能な 23 route**: ES-02 の対応表で確定（既存挙動、federationEnabled 実質 false のため実害なし）。in-process federation の将来（ES-06 の残置判断）と合わせて扱う
- **parseKeyValueMessage の2コピー統一**（MenuBarApp 版は OpsLogSummarizer へ抽出済み、BridgeCore.swift 内部にもう1コピー）
- **lookupTprojOrigin の内部 `ts` 漏れ**（JSDoc 乖離、TD-02 で挙動固定済み）

iteration 0（2026-07-02）の負債マップから、loop の escalate 条件（機能削除 P0 / 公開 API / 仕様がコードから導出不能 / off-limits / スコープ大）に該当した15件。各提案 = {何を / なぜ / どう検証 / 触るファイル}。

## ES-01 ClawGateRelay の退役 — 推定効果: 大
- **何を**: Package.swift の `ClawGateRelay` executable target、`ClawGateRelay/main.swift`(1433行)、並行実装 (RelayTmuxShell/RelayCCStatusClient/RelayTmuxRouter) を削除し、e2e 2本 (ES-13) と `restart-macmini-openclaw.sh:117-118` の防御 pkill を整理する。
- **なぜ**: 2026-02-13 の Direct Federation 移行で deprecated（README.md:428 明記、memory とも一致）。現行 deploy フロー (post-task-restart.sh 系) は Relay を起動しない。ビルド時間と重複メンテの純コスト。
- **どう検証**: 削除前に (1) e2e 2本が運用で叩かれていないこと、(2) macmini 上で Relay プロセスが実際に走っていないことを実測。削除後 full ladder 全緑 + post-task-restart.sh での通常 deploy 成功。
- **触るファイル**: Package.swift / ClawGateRelay/ / scripts/federation-e2e.sh / scripts/host-a-host-b-e2e.sh / restart-macmini-openclaw.sh(off-limits deploy chain 含む)
- **escalate 理由**: 機能削除 P0（ユーザー明示 GO 必須）+ deploy chain 接触。

## ES-02 ルート定義3重化の単一ソース化
- **何を**: BridgeRequestHandler.swift の routes table(:19-56) と if-else dispatch(:116-262)、BridgeCore.handleFederationCommand の switch(:1710-1750) を単一のルート定義から生成する形に統合。
- **なぜ**: エンドポイント追加/改名で3箇所の同期編集が必要。405-vs-404 guard(:98) が table と chain の一致に暗黙依存。
- **どう検証**: 先に「全エンドポイント × メソッドの routing characterization matrix」テストを書いて現挙動を固定してから統合。405/404 の response = 公開契約なので shape 不変を assert。
- **触るファイル**: BridgeRequestHandler.swift / BridgeCore.swift / Tests/UnitTests/（新規 matrix）
- **escalate 理由**: 公開 API 契約（405/404 挙動）+ characterization matrix が先。

## ES-03 doctor() 246行の分解
- **何を**: BridgeCore.swift:1453-1699 の doctor スイートを `DoctorChecks` 型へ抽出。
- **なぜ**: 既に private helper 群に分かれており凝集単位として抽出可能。BridgeCore 減量の一手。
- **どう検証**: `/v1/doctor` response shape は ops tooling が消費するため、抽出前に現 shape の characterization test（testDoctorIncludesLineHealthChecks の拡張）で固定。
- **escalate 理由**: response shape = 公開 API 扱い。

## ES-04 send() 161行の関心分離
- **何を**: BridgeCore.swift:558-719 を decode / federation-forward / line-forward / dispatch に分離。
- **なぜ**: 送信ホットパスに4関心が絡み合い変更コスト高。
- **どう検証**: testSend* 9本が既に invalid payload/adapter-not-found/retriable/line-disabled をカバー = 安全網あり。分離後 9本 + full ladder 全緑。
- **escalate 理由**: コアホットパスの大手術で今回 cap 外。安全網が厚いので次 run の separation 主候補。

## ES-05 Safari-OAuth AX クラスタ（~250行 test ゼロ）
- **何を**: oauthSafariOpen(:965-1075) + AX helper 群(:2582-2714) を独立型へ。
- **なぜ**: Accessibility 自動化が BridgeCore に埋没、テストゼロ。
- **どう検証**: AX 挙動はコードから導出不能 → live Safari での手動検証が必須。characterization test 不可。
- **escalate 理由**: 仕様がコードから判断できない + off-limits (AXActions/AXQuery) 隣接。

## ES-06 「federation は vestigial」コメントの矛盾
- **何を**: BridgeCore.swift:1705-1707 のコメントが「federation server is no longer started」と主張するが、main.swift:202 は条件付きで `federationServerInstance?.start()` を呼び、FederationClient.swift:226 が handleFederationCommand を能動使用。federation の死活を確定させ、コメントを実態に合わせる（または本当に dead なら ES-01 と合わせ退役提案）。
- **どう検証**: 実運用ログで federation 経路の使用実績を確認してから。
- **escalate 理由**: 誤コメントを信じた誤削除の誘発リスク。事実確定が先。

## ES-07 typingBusyStreakCount が write-only
- **何を**: BridgeCore.swift:40 の counter は inc/reset/log されるが判定で read されない。dead telemetry なら削除、未完成 throttle なら完成、の二択を御主人様に確認。
- **escalate 理由**: 意図がコードから判断できない。

## ES-08 PetModel god-object の段階分割（1665行・10責務超）
- **何を**: 段階分割計画（1責務ずつ、各段階で characterization test 先行）を別途設計し承認を得る。
- **なぜ**: connection/send/event routing/history/notification/whisper/idle/window tracking/capture/summon/clipboard が1型に同居。全面分割は大手術で loop の「小さく安全」原則の外。**加えて Pet tracking 系は memory P0 で Cdx 所有（CC 編集禁止）— 分割は Cdx 主導が必須**。
- **どう検証**: TD-11 の小抽出が突破口。各段階 full ladder 全緑 + Pet UI の手動 smoke。
- **escalate 理由**: スコープ大 + Pet 所有権（Cdx）。段階計画の承認が先。

## ES-09 MenuBarAppDelegate god-class の段階分割（1331行）
- **何を**: window 管理・Ghostty follow・stats refresh・ログ整形・panel 制御の段階分割計画を設計し承認を得る。
- **なぜ**: 全面分割は大手術。TD-10（OpsLogSummarizer 抽出）が第一歩として完了済み。
- **どう検証**: 各段階 characterization test 先行 + full ladder 全緑。
- **escalate 理由**: スコープ大。段階計画の承認が先。

## ES-10 PetBubbleView / PetWindow の精査と分割（950行級・無テスト）
- **何を**: レイアウト計算・状態遷移の純粋部分を特定してから抽出計画を立てる（まず内部精査）。
- **なぜ**: AppKit 束縛が濃く、事前精査なしの抽出はリスクだけ高い。Pet 配下のため所有権確認も必要。
- **どう検証**: 精査 → 純粋ロジック抽出 → テスト。
- **escalate 理由**: 要追加調査 + Pet 所有権確認。

## ES-11 テストが gateway.js 純関数を手写しコピー
- **何を**: send-telegram-tag.test.js:14-38 と line-ingress-noise-filter.test.js:12-134 は gateway.js の関数のインラインコピーを検証しており、本体変更時に stale コピーが pass し続ける false green リスク。本修正 = gateway.js から純関数を export してテストが import する形。
- **escalate 理由**: frozen (LINE クリティカル) gateway.js への export 追加が必要。変更自体は挙動不変の export 追加のみなので、御主人様 GO があれば低リスクで実施可能。

## ES-12 release.env source ボイラープレート5箇所重複
- **何を**: `set -a; source .../release.env; set +a` + SIGNING_ID 解決が dev-deploy.sh:84 / restart-local-clawgate.sh:128 / macmini-local-sign-and-restart.sh:20 / provision-diarizer.sh:36 / release-usual.sh:14 に重複。lib-ops-log.sh の前例に倣い共有 helper 化。
- **escalate 理由**: 5箇所中3箇所が off-limits deploy chain。deploy chain を触る GO が必要。

## ES-13 e2e script の stale Relay 参照
- **何を**: federation-e2e.sh / host-a-host-b-e2e.sh が deprecated Relay 経路を叩く。ES-01 の決定に従い archive か direct-federation 前提へ書き直し。
- **escalate 理由**: ES-01 と連動。単独で盲目編集しない。

## ES-14 Chrome manifest の冗長 permission
- **何を**: `activeTab`(manifest.json:9, 固有コード無し) と `http://127.0.0.1:*/*`(:15, `http://*/*` に包含) を削除。
- **どう検証**: 権限変更は拡張 reload + capture-and-send の実機 smoke が必須 = loop 内で自動検証不能。
- **escalate 理由**: 検証がコード外（実機 Chrome）。

## ES-15 単一 caller 抽象の扱い
- **何を**: RetryPolicy.swift(30行, caller は LINEAdapter のみ) / GenericInputSelectors.swift(95行, caller は DraftPlacer のみ)。inline 統合か汎用抽象のまま維持かの設計判断。
- **escalate 理由**: 統合 = 事実上の削除で機能削除 P0 に接触。現状維持コストも低いので低優先。
