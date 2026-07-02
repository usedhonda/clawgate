# ES-09 決着: MenuBarAppDelegate（1236行）段階分割計画（2026-07-02）

読み専精査（sonnet survey）+ main 検収済み。実装は承認単位ごとに別途着手。TD-10（OpsLogSummarizer）と同じ enum/static 純関数 + characterization test パターン。

## 第1段 — 純粋ロジック抽出 + テスト（1項目 = 1コミット、即着手可能な粒度）
1. SessionDeduplicator ← deduplicateByProject（MenuBarApp.swift:1021-1039。running>waiting_input>other 優先度をテスト化）
2. LogRunCollapser ← deduplicateRuns（:1149-1172。連続 event の ×N 集約）
3. PanelSnapMath ← detectSnapSide + area（:627-635, :662-665。CGRect 幾何のみ・依存ゼロ）
4. SessionModeResolver ← dominantSessionMode 判定部（:1111-1117。config 読取は delegate に残す）
5. LogLineStyler ← compactLogStyle（:1174-1205。event→色マップ。OpsLogSummarizer 隣接）
6. PanelGeometry 拡張 or PanelGeometry 新設 ← 幾何群6関数（:407-421, :540-585, :667-682。NSScreen frames 注入で純粋化。大きければ「screen 非依存」「clamp/anchor」の2コミットに分割）

## 第2段 — サブコントローラ分割（characterization は snapshot/log ベース）
7. StatusItemController（:111-174 + :1053-1117）
8. LogTimelinePresenter（:1126-1145 + Styler/Collapser 合成）
9. PanelSnapController（follow/snap state machine :587-847 + findTproj/findGhostty :431-538 — **tickPanelFollow の状態多重書き込みは一体で移す**）
10. PanelCollapseController（:849-966。9 と drift flag / normalPanelWidth を共有するため 9 と同時 or 直後）

## 第3段 — delegate 中核の縮小
11. MenuBarAppDelegate をライフサイクル / panel 構築 / window level observer / open-toggle 戦略 / quit-timer-delegate の orchestration に専念させる

## 壊れやすい箇所（分割時の必読リスト）
- showStatusItemMenu の「menu 一時セット → async nil 復帰」二段構え（左クリ toggle 復帰）
- activationObserver（NSWorkspace）の deinit 解除 / petVisibilityObserver（Combine）— 解除責務ごと移す
- tickPanelFollow は snap 状態6種 + timer 再スケジュールを相互依存更新 — 部分移設禁止
- drift watchdog の世代管理（suspendDriftWithWatchdog / collapse completion が flag を跨ぐ）— snap 側がオーナー、collapse から叩く形
- normalPanelWidth/Origin は collapse/expand/open 戦略/restore の4者が読み書き — 二重ソース化しない
- saveCurrentFrame の抑制条件（!isCollapsed, !isGhosttySnapped）— frame 永続化は delegate 残置が無難
- applyMainPanelLevel の冪等ガードは observer とペアで移す
