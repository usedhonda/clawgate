# ClawGate v0.3.1

## Summary
- Public-facing wording is now messenger-first (LINE is documented as the current adapter, not a hard requirement everywhere).
- Settings and diagnostics text now use "Messenger (LINE)" phrasing for clearer cross-messenger positioning.
- Ops log compact labels for outbound chat send events were simplified (`MSG SEND`, `MSG OUT OK`).

## Breaking Changes
- None.

## Permissions / Re-auth
- Accessibility: Existing grant should continue to work; if missing, re-enable in System Settings > Privacy & Security > Accessibility.
- Screen Recording: Existing grant should continue to work; if OCR capture fails, re-enable in Screen Recording permissions.
- Server role prerequisites (current adapter): local OpenClaw gateway running and LINE Desktop installed/running.

## Known Issues
- OCR-based inbound capture (LINE adapter) can still miss edge-case long/complex bubbles; tuning is ongoing.
- If Tailscale/Federation environment is unstable, session relay state may take a short time to converge after restart.

## Rollback
- Previous stable release: v0.3.0
- Rollback steps: see `docs/runbooks/rollback.md`

## Support
- Include `trace_id` from Ops Logs when reporting issues.
- Run `scripts/support-diagnostics.sh [trace_id]` and attach output.
