# CLAUDE.md 全面リライト

## 指示
v4〜v7 の open_conversation 修正で繰り返された失敗パターン（ユーザーへの依頼、API だけで判断、推測修正）を根絶するため、CLAUDE.md を「AI 自律完結」を最上位原則として全面リライト。

## 変更ファイル
- `CLAUDE.md` — 全面リライト（77行 → 157行）

## 新構造
1. **AI-Autonomous Development**（最重要、最上部）
   - Self-Service Operations テーブル: 9操作に具体コマンドと「NEVER say this」反例
   - Build-Deploy Pipeline: コード変更後の一気通貫コマンド
   - Human Intervention Required: 3操作のみ（AX初回付与、トグルOFF→ON、LINE インストール）
   - `tccutil reset` 永久禁止を明記

2. **Debug Workflow**
   - 9ステップの観察→仮説→検証サイクル（全 AI ツール完結）
   - Fact vs Hypothesis 分離ルール

3. **Quick Reference** / **Key Files** — 現状維持

4. **Common Pitfalls** — カテゴリ化
   - Threading (NIO + BlockingWork)
   - AX / Qt (LINE)
   - Build

5. **Language Rules** / **Conventions** — 統合・簡潔化

## 検証結果
- 全文英語: PASS
- SPEC.md と重複なし: PASS
- 全操作に AI コマンド明記: PASS
- 「人に頼る」記述なし（例外リスト以外）: PASS
- Human Intervention 網羅的: PASS

## 削除した旧セクション
- Autonomy Rules（日本語混在 → AI-Autonomous Development に英語で統合）
- File Conventions / Git Conventions（Conventions に統合）
