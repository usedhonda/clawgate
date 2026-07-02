# ES-05 決着: Safari-OAuth AX クラスタ抽出計画（2026-07-02）

読み専精査（sonnet survey）+ main 検収済み。実装は承認単位ごとに別途着手。

## クラスタ構成（BridgeCore.swift）
- entry: oauthSafariOpen（:964-1073, HTTP handler）/ DTO: SafariOAuthAXAttempt（:2576-2579）
- AX flow: runSafariOAuthAXFlow（:2581-2638, AXAppWindow/AXActions 依存）/ closeSafariFrontTab（:2696-2709, osascript）
- 純粋4関数: findMatchingAXButton（:2640-2665）/ normalizeOAuthAXText（:2667-2672）/ summarizeAXNode（:2674-2682）/ safariObservedURL（:2684-2694）— AX API 呼出ゼロ、テストは `AXUIElementCreateApplication(getpid())` + @testable import でダミー AXNode 構築可（AXQuery 不変更）

## 第1段 — live 検証不要（即着手可能）
純粋4関数を enum SafariOAuthAXMatcher へ verbatim 移動（private→static のみ）+ characterization test（スコアリング/minY tie-break/URL 抽出/非空選択/正規化）。挙動不変が構造保証。

## 第2段 — 機械的移動（構造的不変）
runSafariOAuthAXFlow + DTO + closeSafariFrontTab を SafariOAuthFlow 型（新規ファイル、**同一 app ターゲット内必須**）へ。logger は init 注入、AXActions/AXQuery/AXAppWindow は static 呼びのまま。clickSequence の日本語リテラルは oauthSafariOpen 側残置（配布物/個人分離ルール）。oauthSafariOpen は thin delegate 化して BridgeCore 残置。

## 第3段 — live 検証（御主人様同席、1回）
deploy → 実 OAuth URL →「Google で続行」→「続行」自動クリック目視 → response JSON（clickedLabels/observedURL/opened）同型確認 → closeTab:true の cmd-W 確認 → oauth_button_not_found / timeout 挙動不変確認。

## 不変条件（drive-by 変更厳禁）
- sleep(3.0)×2 / 0.25s poll / deadline 算術は verbatim 保存
- withWindow の呼出スレッド文脈を変えない（別 queue 載せ替え禁止）
- **TCC**: 抽出先は必ず同一 app ターゲット内（別バイナリ切出は Accessibility/Screen Recording が剥がれる）
- 層B テストの @testable import 前提はテストターゲット設定を第1段着手時に確認
