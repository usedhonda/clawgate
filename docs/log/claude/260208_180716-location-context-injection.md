# Location Context Injection into AI Prompt

**Date**: 2026-02-08 18:07
**Task**: vibeterm-telemetry の位置情報を OpenClaw AI のコンテキストに注入

## Summary

vibeterm-telemetry プラグインが受信した位置情報を、openclaw-plugin が AI プロンプトに自動注入するようにした。

## Architecture

```
Vibeterm iOS -> POST /api/telemetry -> store.js -> globalThis.__vibetermLatestLocation
                                                          |
LINE Message -> ClawGate -> openclaw-plugin -> buildMsgContext()
                                                |- Body: original text (log/echo suppression)
                                                +- BodyForAgent: "[User location: ...]\n\n{text}" -> AI
```

## Changes

### 1. `extensions/vibeterm-telemetry/src/store.js` (+1 line)

- `storeSample()` で `latestLocation = entry;` の直後に `globalThis.__vibetermLatestLocation = entry;` を追加
- 同一プロセス内の他プラグインから最新位置にアクセス可能に

### 2. `extensions/openclaw-plugin/src/gateway.js` (+25 lines)

- `buildLocationPrefix()` 関数を追加:
  - `globalThis.__vibetermLatestLocation` から最新位置を読み取り
  - 24時間以上古いデータは除外
  - フォーマット: `[User location: 35.6762, 139.6503, accuracy 10m, just now]`
- `buildMsgContext()` を変更:
  - 位置プレフィックスがある場合、`BodyForAgent` に `{prefix}\n\n{text}` を設定
  - `Body` はそのまま（ログ・echo 抑制に影響なし）

### 3. `/Users/usedhonda/projects/ios/vibeterm/openclaw-plugin/src/store.js` (+1 line)

- iOS リポジトリ側にも同じ `globalThis.__vibetermLatestLocation` 追加

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| `globalThis` for cross-plugin data | Same process guaranteed, no API needed, graceful degradation |
| `BodyForAgent` over `Body` | Keeps `Body` clean for logs/echo suppression |
| 24h expiry | Users stay in one place; only discard very stale data |
| 4 decimal places | ~11m precision, neighborhood-level accuracy |

## Verification

- `dev-deploy.sh`: 6/6 smoke tests PASS
- OpenClaw gateway: auto-pair OK, doctor OK, polling started
- Telemetry: `processed 1 samples, 1 new` confirmed in gateway log
