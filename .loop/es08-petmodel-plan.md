# ES-08 決着: PetModel（1653行）2レーン段階分割計画（2026-07-02）

読み専精査（sonnet survey）+ main 検収済み。**レーンB の実装は Cdx 所有（memory P0）— CC はリレーと検証のみ**。正本 spec は `docs/pet-behavior-spec.md`（§Trigger→Behavior と §Invariants を SoT とする。§Working Tree Recommendation は stale なので無視 — 該当パッチはコミット済 + TD-11 反映済み）。

## レーンA — CC 可（純粋ロジック、1項目 = 1コミット、小さい順）
- A1. 静的設定ローダ load*（PetModel.swift:95-112）→ PetSettings（純パース、依存ゼロ）
- A2. isLocalSource + source 分類（:1439-1446）→ 純関数化
- A3. PetLogStore（:1630-1653）を別ファイルへ移設
- A4. app 分類 messaging/terminal/browser（:1054, :1224-1234, :1361）→ PetAppClassifier
- A5. AX テキスト抽出 dedup/join/trunc（:1079-1092)→ 純関数（nodes 与件）+ テスト
- A6. tmux 出力パース（:1173, :1460-1468）→ 純関数（文字列与件）
- A7. Summon prompt ビルダ（:1204, :1258, :1317）→ 純テンプレ（ScreenContext 与件）
※ lastTrackedApp/Window/Frame トリオは tracking と共有 — レーンA は read-only 参照に留める。

## レーンB — Cdx 主導（tracking/hide/facing/movement、依存順）
- B1. PetRenderMetrics（:7-53）別ファイル化 + 純幾何テスト
- B2. TrackedWindowResolver（resolveTrackedWindow :624-649 + screenForTrackedFrame :610-622 + appKitRect 呼び出し）
- B3. placement lock 状態機（lockedPlacementSide/Frame + pin 群 :562-589, :679-693）
- B4. updateTargetPosition 系（:652-858）— B1〜B3 依存、最後
- B5. hide lifecycle（enter/unhide/micro/zzz/setHiddenSide :938-1045, :591-603）— B4 依存、最終段

## 壊れやすい箇所（既知6者 + 精読で判明した追加8点）
1. isHiding は隠れた7人目の束メンバー（tick 間引き :549-558 / idle guard :528 / noteActivity が読む）
2. updateTargetPositionImmediate の temporal coupling（isHiding を一時 false→復元 :653-682、early-return 毎に手動復元）
3. 原子束の二重代入（enterHiding が setHiddenSide 後 :967 で suffix 再代入 — spec §Required atomicity）
4. expression/isExpressionLocked/hideAnimationSuffix の PetModel×PetStateMachine 二重管理
5. unhideWaveOnArrival one-shot flag の消費順（:696-697）
6. pendingSummonSource が delta/message/finishStreaming/addSummonResult を貫通（summon 応答の chat 漏れ既知対策 :1344）
7. lastTrackedApp/Window/Frame の tracking×capture 共有
8. lastActivityTime の意図的非リセット（:529 — idle cycle は activity ではない。hideAfterMinutes=0 事故と同系統の再発面）

## spec 乖離メモ
- §Working Tree Recommendation（L283-297）は stale（行動指示は無効）— spec 更新は Cdx へ依頼事項
- whisper 位置決めは view 層委譲が現実装（spec §Whisper Positioning とは責務配置が異なる）— hide 抽出時に「PetModel 責務外」を前提化
