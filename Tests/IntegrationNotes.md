# Integration Notes

## Manual checklist

1. AppBridge を起動し、メニューバーに `AppBridge` が表示されること。
2. Settings で token が表示され、Regenerate 後に値が変わること。
3. `curl http://127.0.0.1:8765/v1/health` が成功すること。
4. `X-Bridge-Token` を付けずに `/v1/send` を叩くと 401 になること。
5. Accessibility 権限を付けた状態で `/v1/axdump` を叩き、LINE起動中ならJSONが返ること。
6. LINE を開いた状態で `/v1/send` を叩き、送信の成功/失敗が構造化エラーで確認できること。
7. `/v1/poll` と `/v1/events` で heartbeat イベントが取得できること。
