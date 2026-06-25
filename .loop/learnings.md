# Loop learnings — swift test 全緑（毎 run 開始時に contract より先に読む）

恒久ルール（再発失敗から1つずつ追記。クラスごと殺す予防を優先）:

- **LINE 無効時の send は「forward 契約」**: `lineEnabled=false` + adapter=`line` の send は reject ではなく remote openclawHost へ forward される（`BridgeCore.rejectLineOnClient` -> `forwardLineRequest`）。openclawHost が loopback（localhost/127.0.0.1/::1/0.0.0.0）だと forward 先が無く **503 `line_forward_unavailable`** を返す。旧 **403 `line_disabled`** は廃止済（送信パスに該当コードは存在しない）。LINE 無効まわりのテスト/挙動を扱うときは forward 契約を前提にすること。

## 観察待ちの仮説（確定したらルールへ昇格）
- （現状なし）
