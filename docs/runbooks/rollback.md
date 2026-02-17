# Rollback Runbook

Use this when the latest release causes user-facing failures.

## Preconditions

- Previous stable release tag is known (`vX.Y.Z`)
- Previous DMG artifact is available in GitHub Releases

## Rollback policy

- Target recovery time: within 30 minutes
- Rollback means: stop recommending latest, distribute previous stable DMG, and verify Host A/Host B health

## Steps

1. Identify last stable release tag.
2. Update release notes / incident note to mark latest as degraded.
3. In GitHub Releases:
   - Keep broken release for traceability, but clearly mark as problematic.
   - Point users to previous stable release tag.
4. Re-deploy previous stable DMG to validation machines.
5. Restart and verify both hosts:

```bash
./scripts/post-task-restart.sh --remote-host macmini --project-path /Users/usedhonda/projects/ios/clawgate
```

6. Confirm runtime health:

```bash
curl -s http://127.0.0.1:8765/v1/health
curl -s http://127.0.0.1:8765/v1/doctor
```

7. Validate end-to-end path:
   - client capture -> federation -> server ingress -> gateway -> LINE send

## Evidence to retain

- Broken release tag/version
- Stable rollback tag/version
- Time started / time recovered
- Root cause summary and preventive action
