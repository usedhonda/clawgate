# ClawGate v0.3.3

## Summary
- Menu panel now snaps to a visible Ghostty window using `CGWindowList` (no AX dependency for tracking source).
- Panel follow behavior while Ghostty moves is smoother and supports manual detach/re-snap behavior.
- Placement offsets were tuned (vertical alignment and tighter horizontal gap) while preserving off-screen clamping and fallback to status-item placement when Ghostty is absent.

## Breaking Changes
- None.

## Permissions / Re-auth
- Accessibility: Existing grant should continue to work; if missing, re-enable in System Settings > Privacy & Security > Accessibility.
- Screen Recording: Existing grant should continue to work; if OCR capture fails, re-enable in Screen Recording permissions.
- Server role prerequisites (current adapter): local OpenClaw gateway running and LINE Desktop installed/running.

## Known Issues
- OCR-based inbound capture (LINE adapter) can still miss edge-case long/complex bubbles; tuning is ongoing.
- Ghostty-follow behavior depends on Ghostty exposing a normal on-screen layer-0 window; hidden/minimized windows intentionally fall back to status-item placement.

## Rollback
- Previous stable release: v0.3.2
- Rollback steps: see `docs/runbooks/rollback.md`

## Support
- Include `trace_id` from Ops Logs when reporting issues.
- Run `scripts/support-diagnostics.sh [trace_id]` and attach output.
