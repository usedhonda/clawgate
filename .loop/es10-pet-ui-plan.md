# ES-10 決着: PetBubbleView / PetWindow 精査結果と段階分割計画（2026-07-02）

読み専精査（sonnet subagent）+ main 検収済み。**実装はこの計画の承認単位ごとに別途着手**（Pet 配下は実装後に Cdx レビュー必須 — TD-11 と同運用）。

## 線引きの原則
- hide/placement/tracking state を**読むだけの純粋計算**（clamp・寸法・時刻・アイコン変換）= CC レーンで抽出可
- それらを**セマンティクスとして解釈する配置ロジック**（whisperOrigin, bubbleX の placement 分岐, mouse ドラッグ, bind/stop）= Cdx 所有

## 第1段 — 純粋ロジック抽出 + テスト（CC レーン、小さい順）
1. 時刻フォーマッタ4重複の集約（PetBubbleView.swift:353,687,852,943 → hhmm formatter 1本）+ テスト
2. NotificationSourceStyle 純粋マッパー新設: source → (SF Symbol, Color, label)。3ビューの重複（:667/:677、:825/:834/:843、:919/:932）を差替
3. ClipboardContentType → SF Symbol 純粋関数化（:192）+ enum 網羅テスト
4. PetGeometry へ寸法計算追加: windowSize(charSize+20; PetWindow.swift:24,81) / summon メニュー寸法・配置（:347-352,:416-421）
5. PetGeometry へ initialOrigin（:22-28, screenFrame 注入）+ clampOrigin ヘルパー（:576-579/:733-740/:749-751 の3反復）。差替は placement/hide 非依存の呼び出し元に限定（whisper 側の差替は Cdx 判断）

## 第2段 — Cdx 主導（hide/facing/movement 規約領域）
1. whisperOrigin 純粋化（PetWindow.swift:710-752、hidingSide/isHiding/expression を引数注入）
2. placement 依存 bubbleX の関数化（:567-583、facing 規約として明文化）
3. mouse ハンドリング（:247-294 ドラッグ/unpin/unhide）の責務整理
4. PetContentView（:137-797, 約660行）の3系統サブコンポーネント分割（whisper / summon-menu / notification-chat）

## 触らないもの
show()/hide() の moveController bind/stop（tracking 中核）、updateSpriteForCurrentState、HiddenClawAssetMetrics。
