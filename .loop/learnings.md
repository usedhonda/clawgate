# Loop learnings — swift test 全緑（毎 run 開始時に contract より先に読む）

恒久ルール（再発失敗から1つずつ追記。クラスごと殺す予防を優先）:

- （まだ無し。最初の run でルールを書き始める）

## 観察待ちの仮説（確定したらルールへ昇格）
- LINE 無効時の send レスポンスコードが 403/`line_disabled` -> 503/`line_forward_unavailable` に変わっている。これが意図的な仕様変更（forward 不能を 503 で表す）なら、`testLineSendIsRejectedWhenLineDisabled` の期待値を更新するのが正。regression なら code を直すのが正。**run 1 でどちらか確定し、ここに結論を書く。**
