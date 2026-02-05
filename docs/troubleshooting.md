# Troubleshooting

- `unauthorized`:
  - Settings で token を確認し、`X-Bridge-Token` を一致させる。
- `ax_permission_missing`:
  - System Settings > Privacy & Security > Accessibility で AppBridge を許可。
- `line_not_running` / `line_window_missing`:
  - LINEを起動し、通常ウィンドウを前面に表示。
- `search_field_not_found` / `message_input_not_found`:
  - `/v1/axdump` を実行し、`LineSelectors` を環境に合わせて更新。
- SSEが来ない:
  - `/v1/events` 接続中か確認、`/v1/poll` でイベント蓄積を切り分け。
