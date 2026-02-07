# pasteText デバッグ + 自己署名証明書セットアップ

## 日時
2026-02-07 18:32

## 成果
1. **自己署名証明書** (`ClawGate Dev`) セットアップ完了
   - `scripts/setup-cert.sh` — LibreSSL で P12 作成、Keychain にインポート
   - ビルドごとの AX 権限再付与が不要に（証明書 identity で TCC 追跡）
   - `codesign --sign "ClawGate Dev"` で署名
   - Homebrew OpenSSL 3.x は P12 非互換 → `/usr/bin/openssl` (LibreSSL) を使用

2. **pasteText 問題を特定**
   - `open_conversation` ステップで pasteText(Cmd+A, Cmd+V) が検索フィールドに入力されていない
   - 検索フィールド value が空のまま → 検索が実行されない → ナビゲーション失敗
   - clickAtCenter や AXPress の問題ではなく、**テキスト入力自体が機能していない**

## 検証の事実
- `AXPress(searchField)` → OK（エラーなし）
- `pasteText("<CONTACT_NAME>")` → 実行されるが検索フィールド value = "" のまま
- `clickAtCenter(row)` → 既存サイドバー行をクリック（ナビゲーションせず）

## 仮説
- HID Cmd+V が LINE に届いていない（ClawGate 自体がフォーカスを奪っている?）
- activate() 後の 150ms が不十分で、LINE が HID イベントを受信する準備ができていない
- BlockingWork.queue から実行しているため、activate() のメインスレッド呼び出しとの競合

## 次のアクション
- pasteText の代わりに `AXUIElementSetAttributeValue(kAXValueAttribute)` を試す
  （Qt の textEdited() は発火しないが、少なくとも値は入る）
- 値セット後に `sendSearchEnter()` (HID Enter) で検索を強制トリガー
- または pasteText のタイミングを調整（activate 後の待機時間を増やす）

## ファイル変更
- `ClawGate/Adapters/LINE/LINEAdapter.swift` — open_conversation ステップ修正中
- `ClawGate/Automation/AX/AXActions.swift` — clickAtCenter に restoreCursor 追加
- `scripts/setup-cert.sh` — 自己署名証明書セットアップスクリプト
- `CLAUDE.md` — 自律実行ルール追加、tccutil reset 禁止ルール追加
