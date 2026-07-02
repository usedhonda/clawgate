# Tech-Debt Escalations（提案のみ・実装は御主人様 GO 待ち）

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

## ES-08〜ES-10 God-object 全面分割（PetModel 1665行 / MenuBarAppDelegate 1331行 / PetBubbleView・PetWindow 950行級）
- **何を**: 段階分割計画（1責務ずつ、各段階で characterization test 先行）を別途設計し承認を得る。
- **なぜ**: PetModel は10責務超（connection/send/event routing/history/notification/whisper/idle/window tracking/capture/summon/clipboard）。全面分割は大手術で loop の「小さく安全」原則の外。
- **どう検証**: TD-10/TD-11 の小抽出が突破口。各段階 full ladder 全緑 + Pet UI の手動 smoke。
- **escalate 理由**: スコープ大。段階計画の承認が先。

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
