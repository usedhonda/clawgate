# 002 intel-compatibility

## 指示内容
- 古いMac mini（5年前想定）でも動作させたい。Intel対応を考慮したい。

## 実施内容
- `Package.swift` の `swift-tools-version` を `5.9` へ下げ、古いXcode環境でのビルド互換性を改善。
- `Package.swift` の最小対応OSを `macOS 12` に変更し、Intel Mac miniのMonterey系を対象化。
- テストを `Testing` から `XCTest` に移行し、古いツールチェーンでも実行しやすく調整。
- `docs/architecture.md` に Intelサポート方針とクロスビルド例を追記。

## 課題、検討事項
- 実機のOSバージョンが `macOS 11` の場合は、最小ターゲットをさらに下げる追加調整が必要。
- この環境では sandbox 制約で `swift test` は引き続き未実行。実機検証が必要。
