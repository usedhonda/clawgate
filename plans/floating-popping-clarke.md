# ClawGate パブリック化 & 初回リリース

**目的**: cc-status-barと同じ運用でパブリックリリースする

---

## セキュリティ確認 ✅

| 項目 | ClawGate | cc-status-bar |
|------|----------|---------------|
| APP_PASSWORD | ✅ 環境変数/.local/ | ⚠️ ハードコード済み（要再生成） |
| .local/ | ✅ .gitignore済み | - |
| APPLE_ID/TEAM_ID | 公開情報（署名者として公開） | 同左 |

**注意**: cc-status-barのAPP_PASSWORDが漏洩済み。appleid.apple.comで再生成推奨。

---

## 現状

- リポジトリ: `usedhonda/clawgate` (現在プライベート)
- 未コミット変更: Phase 1-4で実装した全機能
  - Doctor機能 (`/v1/doctor`)
  - ペアリング機能 (`/v1/pair/request`, `PairingCodeManager`)
  - メニューバーUI（🦀アイコン、ペアリングコード表示）
  - リリーススクリプト (`scripts/release.sh`)
  - App bundle (`ClawGate.app/`)
  - ドキュメント

---

## 実行手順

### Step 1: 変更をコミット

```bash
git add -A
git commit -m "feat: add Doctor, Pairing, release infrastructure"
```

### Step 2: リポジトリをパブリック化

```bash
gh repo edit usedhonda/clawgate --visibility public
```

### Step 3: プッシュ

```bash
git push origin main
```

### Step 4: APP_PASSWORD設定

`.local/release.md` に App-specific password を設定

### Step 5: リリース実行

```bash
./scripts/release.sh --publish
```

### Step 6: Homebrew Tap作成

```bash
# 1. Tapリポジトリ作成
gh repo create homebrew-clawgate --public --description "Homebrew tap for ClawGate"

# 2. クローン
cd ~/projects
git clone git@github.com:usedhonda/homebrew-clawgate.git
cd homebrew-clawgate
mkdir -p Casks

# 3. SHA256計算
shasum -a 256 /tmp/ClawGate.dmg

# 4. Cask作成 (Casks/clawgate.rb)
# 5. コミット＆プッシュ
```

---

## 検証

```bash
# インストールテスト
brew tap usedhonda/clawgate
brew install --cask clawgate

# 動作確認
curl http://127.0.0.1:8765/v1/health
curl http://127.0.0.1:8765/v1/doctor -H "X-Bridge-Token: $(security find-generic-password -s com.clawgate.local -a bridge.token -w)"
```

---

## 注意事項

- cc-status-barと同じApple認証情報を使用（APPLE_ID, TEAM_ID, APP_PASSWORD）
- APP_PASSWORDは `.local/release.md` から読み込み
