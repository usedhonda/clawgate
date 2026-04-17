# Chi Bubble Routing

Survey date: 2026-04-17
Scope: ClawGate が Chi 発話を受け取り、macOS ネイティブの Chi バブルとして描画するまでの routing 実態。

## Fact / Hypothesis

### Fact
- ClawGate には **2本**の Chi バブル入口がある。
  1. OpenClaw Gateway WebSocket の `chat` / `assistant.message` イベントを `PetModel` が購読して `notificationMessage` に流す経路。
  2. BridgeServer の `POST /v1/bubble-notify` が `NotificationCenter.Name.petBubbleNotify` を発火し、`PetModel` がそれを `notificationMessage` に流す経路。
- LINE 送信 (`/v1/send` adapter=`line`) は別経路で、Chi バブル表示の必須条件ではない。
- Chi バブル表示は `PetWindow` の child window (`notificationWindow`) で描画され、LINE AX 操作や Federation とは直接結合していない。
- アイコン prefix (`ちー`, emoji, sender 名) によるフィルタは見当たらない。表示判定は event type / role / state と UI state (`isBubbleEnabled`, `isChatOpen`) で決まる。

### Hypothesis
- 現在の openclaw-plugin / Gateway 側コードからは `POST /v1/bubble-notify` の呼び出し元が確認できなかった。実運用では Gateway WS が主経路で、`/v1/bubble-notify` は補助的な注入経路の可能性が高い。

## 1. 入口チャネル / endpoint

### A. Gateway WebSocket -> PetModel
1. `PetModel.connect()` が `ws://<openclawHost>:<openclawPort>/` に接続し、`OpenClawWSClient.connect(url:token:)` を起動する (`ClawGate/UI/Pet/PetModel.swift:171-197`)。
2. 接続後、`PetModel` は通常セッションと proactive heartbeat セッションを subscribe する (`ClawGate/UI/Pet/PetModel.swift:261-265`)。
   - 通常: `sessionKey`
   - proactive: `agent:main:proactive:heartbeat`
3. `OpenClawWSClient` は Gateway の `chat` / `assistant.message` / `assistant.delta` / `assistant.message_complete` を `OpenClawEvent` へ変換する (`ClawGate/Core/OpenClaw/OpenClawWSClient.swift:304-340`)。
4. `PetModel.handleEvent(_:)` が `.message(OpenClawChatMessage)` を受け、最終的に `showNotification(msg)` を呼ぶ (`ClawGate/UI/Pet/PetModel.swift:268-303`)。

#### Payload contract (一次ソース)
- OpenClaw 正本 contract では Gateway -> Client の chat final は以下 (`~/projects/openclaw/oc-general/docs/contracts/event-contract.md:60-94`)。
  - `event: "chat"`
  - `payload.state: "final"`
  - `payload.runId`
  - `payload.sessionKey`
  - `payload.message.role`
  - `payload.message.content[].text`
- ClawGate 実装では `payload.message.content[].text` を連結し、`sessionKey` に `proactive` が含まれる場合だけ `isProactive=true` を立てる (`ClawGate/Core/OpenClaw/OpenClawWSClient.swift:316-325`)。

### B. BridgeServer /v1/bubble-notify -> NotificationCenter -> PetModel
1. BridgeServer は `POST /v1/bubble-notify` を公開している (`ClawGate/Core/BridgeServer/BridgeRequestHandler.swift:20-35`, `176-185`)。
2. `BridgeCore.bubbleNotify(body:)` は `payload.text` / `payload.source` / `payload.trace_id` を読み、`NotificationCenter.default.post(name: .petBubbleNotify, userInfo: ...)` する (`ClawGate/Core/BridgeServer/BridgeCore.swift:140-157`)。
3. `PetModel.start()` が `.petBubbleNotify` を observer しており、受信時に `OpenClawChatMessage(role:.assistant,text:text)` を生成して `showNotification(msg)` へ流す (`ClawGate/UI/Pet/PetModel.swift:905-917`)。

#### Payload schema (一次ソース)
```json
{
  "payload": {
    "text": "<bubble text>",
    "source": "<string, optional>",
    "trace_id": "<string, optional>"
  }
}
```
根拠: `BridgeCore.bubbleNotify(body:)` (`ClawGate/Core/BridgeServer/BridgeCore.swift:140-157`)。

## 2. Chi バブル描画トリガー条件

### 描画レイヤ
- `PetModel.notificationMessage` が non-nil になると、`PetContentView` の `bubbleObservation` が `showNotification()` を呼ぶ (`ClawGate/UI/Pet/PetWindow.swift:165-175`)。
- `showNotification()` は borderless child `NSWindow` を生成し、`PetNotificationBubble(model:)` を内容として表示する (`ClawGate/UI/Pet/PetWindow.swift:541-585`)。
- SwiftUI 側では `model.notificationMessage` がある時だけ regular notification bubble を描く (`ClawGate/UI/Pet/PetBubbleView.swift:46-74`)。

### 表示条件
`PetModel.showNotification(_:)` の gate は次の2つだけ (`ClawGate/UI/Pet/PetModel.swift:384-402`)。
1. `isBubbleEnabled == true`
2. `stateMachine.isChatOpen == false`

上を満たすと `notificationMessage = msg` にセットされ、15〜60 秒で自動 dismiss される (`ClawGate/UI/Pet/PetModel.swift:394-401`)。

### アイコン prefix / sender prefix 判定
- なし。`showNotification(_:)` は `msg.text` と `msg.isProactive` だけを見る (`ClawGate/UI/Pet/PetModel.swift:384-402`)。
- `/v1/bubble-notify` observer も `text` / `source` をそのまま受けるだけで、prefix 判定はしない (`ClawGate/UI/Pet/PetModel.swift:905-917`)。

### tracking/hide/facing との関係
- 直接結合していない。bubble は `PetWindow` の child window として親 pet window の上に出るだけ (`ClawGate/UI/Pet/PetWindow.swift:541-585`)。
- hide/tracking/facing は pet 本体の位置・スプライト・whisper に関わるが、`notificationMessage` の表示可否 gate ではない。
- したがって「Chi バブルを出す/出さない」の主要条件は routing/event 種別と `isBubbleEnabled` / `isChatOpen`。

## 3. 出るメッセージ / 出ないメッセージ

### 出るメッセージ (コードパスから導出)
1. **Gateway `chat` final の assistant メッセージ**
   - `OpenClawWSClient.handleEvent("chat")` が `.message(msg)` を yield (`ClawGate/Core/OpenClaw/OpenClawWSClient.swift:316-325`)
   - `PetModel.handleEvent(.message)` で `isNew && role == .assistant` の場合 `showNotification(msg)` (`ClawGate/UI/Pet/PetModel.swift:290-303`)
2. **Gateway proactive heartbeat の final メッセージ**
   - proactive session は `agent:main:proactive:heartbeat` を subscribe (`ClawGate/UI/Pet/PetModel.swift:261-265`)
   - `sessionKey` に `proactive` を含むと `isProactive=true` (`ClawGate/Core/OpenClaw/OpenClawWSClient.swift:323-324`)
   - `PetModel.handleEvent(.message)` は proactive を常に notification 側へ送る (`ClawGate/UI/Pet/PetModel.swift:275-279`)
3. **BridgeServer `/v1/bubble-notify` で注入された text**
   - `BridgeCore.bubbleNotify` -> `.petBubbleNotify` (`ClawGate/Core/BridgeServer/BridgeCore.swift:140-157`)
   - `PetModel.start()` observer -> `showNotification(msg)` (`ClawGate/UI/Pet/PetModel.swift:905-917`)

### 出ないメッセージ / 表示されないケース
1. **Gateway `delta` / `assistant.delta` の途中テキスト**
   - `.delta` は streaming text 更新だけで `showNotification()` を呼ばない (`ClawGate/UI/Pet/PetModel.swift:305-338`)
2. **チャットウィンドウが開いている時の assistant message**
   - `showNotification(_:)` は `stateMachine.isChatOpen` なら suppress (`ClawGate/UI/Pet/PetModel.swift:390-393`)
3. **バブル機能を無効にしている時の全メッセージ**
   - `showNotification(_:)` は `isBubbleEnabled == false` なら suppress (`ClawGate/UI/Pet/PetModel.swift:390-393`)

補足:
- `messageComplete` 単体は speak state を閉じるだけでバブル表示しない (`ClawGate/UI/Pet/PetModel.swift:340-345`)。
- user role の送信メッセージは `messages` には入るが notification bubble にはならない (`ClawGate/UI/Pet/PetModel.swift:228-238`, `290-303`)。

## 4. LINE 送信との結合有無

## 結論
**独立。**

### 根拠1: LINE 送信経路は `/v1/send` adapter=`line`
- openclaw-plugin の LINE outbound は `clawgateSend(apiUrl, conversationHint, text)` を呼び、`POST /v1/send` に `adapter:"line"`, `action:"send_message"` を送る (`extensions/openclaw-plugin/src/outbound.js:43-61`, `extensions/openclaw-plugin/src/client.js:82-97`)。
- この経路は `BridgeRequestHandler` の `/v1/send` で処理され、`/v1/bubble-notify` とは別 endpoint (`ClawGate/Core/BridgeServer/BridgeRequestHandler.swift:176-185`)。

### 根拠2: tmux review / LINE delivery routing は別仕様
- `clawgate-channel-routing.md` の正本は LINE/Telegram routing を規定しているが、Chi bubble には触れていない (`~/projects/openclaw/oc-general/docs/runbooks/clawgate-channel-routing.md:11-37`)。
- つまり messenger delivery routing と local bubble UI routing は別 concern。

### 根拠3: bubble 側は `notificationMessage` / `.petBubbleNotify` のみを見る
- `PetContentView` / `PetNotificationBubble` は `notificationMessage` の有無だけでバブル描画する (`ClawGate/UI/Pet/PetWindow.swift:165-175`, `541-585`; `ClawGate/UI/Pet/PetBubbleView.swift:46-74`)。
- LINE 送信成功/失敗を参照するコードはこの系統にない。

## Routing Summary

### Primary route (current likely default)
`Gateway WS chat final / assistant.message`  
→ `OpenClawWSClient.handleEvent(...)`  
→ `OpenClawEvent.message(OpenClawChatMessage)`  
→ `PetModel.handleEvent(.message)`  
→ `PetModel.showNotification(msg)`  
→ `notificationMessage = msg`  
→ `PetContentView.bubbleObservation`  
→ `PetWindow.showNotification()`  
→ `PetNotificationBubble`

### Secondary route (explicit injection)
`POST /v1/bubble-notify`  
→ `BridgeCore.bubbleNotify(body:)`  
→ `NotificationCenter.post(.petBubbleNotify)`  
→ `PetModel.start()` observer  
→ `PetModel.showNotification(msg)`  
→ `PetWindow.showNotification()`

## Practical interpretation for delivery-routing.md
- 「Chi バブル」は LINE/Telegram の messenger delivery matrix とは独立の **local native UI route** として扱うのが正しい。
- current code から見る限り、bubble を出す主経路は Gateway WS の assistant final/proactive final。
- `/v1/bubble-notify` は local injection 用の補助チャネルとして別枠で記述するのが安全。
