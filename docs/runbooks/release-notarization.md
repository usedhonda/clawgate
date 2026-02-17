# Release Notarization Runbook

This runbook defines when to wait, when to re-check, and when to re-submit.

## Inputs

- DMG path (from release output)
- Notary submission ID (from `notary-submit.json`)
- Apple credentials from env (`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_ID_PASSWORD`)

## Decision thresholds

- `T+15m`: Query `history` and `info`. Continue waiting if status is still `In Progress`.
- `T+45m`: Query again. If no change, check Apple system status and network logs.
- `T+90m`: Treat as stalled. Re-submit once from the same DMG and record both submission IDs.
- `>T+180m`: Escalate. Do not publish release.

## Commands

```bash
xcrun notarytool history \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_ID_PASSWORD"

xcrun notarytool info <SUBMISSION_ID> \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_ID_PASSWORD"
```

If re-submit is required:

```bash
xcrun notarytool submit <DMG_PATH> \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_ID_PASSWORD" \
  --wait \
  --output-format json > /tmp/clawgate-release/<timestamp>/notary-resubmit.json
```

## Exit criteria for publish

Publish is allowed only when all are true:

1. Notary status is `Accepted`
2. `xcrun stapler staple <DMG_PATH>` succeeds
3. `spctl --assess --verbose=4 --type install <DMG_PATH>` succeeds

## Failure handling

- `Invalid`: inspect details in notary output, fix signing/runtime issues, rebuild.
- `Rejected`: treat as release blocker.
- `In Progress` over threshold: follow re-submit policy above.
