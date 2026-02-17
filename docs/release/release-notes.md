# ClawGate v0.3.0

## Summary
- Main menu was redesigned around tab navigation (`Sessions`, `Ops Logs`, `Settings`, `VibeTerm`) for faster access.
- `VibeTerm` pairing now shows QR inline in the tab, with clearer OpenClaw integration messaging.
- Menu popover close behavior was stabilized to close reliably on outside click.
- Release pipeline was hardened (manifest output, notarize/staple/assess checks, support diagnostics tooling).

## Breaking Changes
- None.

## Permissions / Re-auth
- Accessibility: Existing grant should continue to work; if missing, re-enable in System Settings > Privacy & Security > Accessibility.
- Screen Recording: Existing grant should continue to work; if OCR capture fails, re-enable in Screen Recording permissions.
- LINE/OpenClaw prerequisites: Server role requires local OpenClaw gateway running and LINE app installed/running.

## Known Issues
- OCR-based LINE capture can still miss edge-case long/complex bubbles; tuning is ongoing.
- If Tailscale/Federation environment is unstable, session relay state may take a short time to converge after restart.

## Rollback
- Previous stable release: v0.1.1
- Rollback steps: see `docs/runbooks/rollback.md`

## Support
- Include `trace_id` from Ops Logs when reporting issues.
- Run `scripts/support-diagnostics.sh [trace_id]` and attach output.
