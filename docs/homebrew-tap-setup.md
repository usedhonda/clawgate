# Homebrew Tap セットアップ

## 1. Tapリポジトリ作成

```bash
gh repo create homebrew-clawgate --public --description "Homebrew tap for ClawGate"
cd ~/projects
git clone git@github.com:usedhonda/homebrew-clawgate.git
cd homebrew-clawgate
mkdir -p Casks
```

## 2. Cask定義作成

`Casks/clawgate.rb`:

```ruby
cask "clawgate" do
  version "0.1.0"
  sha256 "SHA256_OF_DMG"

  url "https://github.com/usedhonda/clawgate/releases/download/v#{version}/ClawGate.dmg"
  name "ClawGate"
  desc "macOS menubar app for LINE automation via Accessibility API"
  homepage "https://github.com/usedhonda/clawgate"

  depends_on macos: ">= :ventura"

  app "ClawGate.app"

  postflight do
    system_command "/usr/bin/open", args: ["-a", "ClawGate"]
  end

  uninstall quit: "com.clawgate.app"

  zap trash: [
    "~/Library/Preferences/com.clawgate.app.plist",
  ]
end
```

## 3. SHA256計算

```bash
shasum -a 256 /tmp/ClawGate.dmg
```

## 4. コミット＆プッシュ

```bash
cd ~/projects/homebrew-clawgate
git add Casks/clawgate.rb
git commit -m "feat: add clawgate cask v0.1.0"
git push origin main
```

## 5. インストール確認

```bash
brew tap usedhonda/clawgate
brew install --cask clawgate
```

## バージョンアップ時

1. `scripts/release.sh --publish` でDMGをリリース
2. SHA256を計算
3. `Casks/clawgate.rb` の version と sha256 を更新
4. コミット＆プッシュ
