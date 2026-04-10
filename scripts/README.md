# Scripts Guide

This directory contains both end-user helpers and maintainer-only operational scripts.

## User-facing scripts

These are reasonable entry points for contributors and local users:

| Script | Purpose |
|------|---------|
| `restart-local-clawgate.sh` | Build, sign, launch, and smoke-check the local app |
| `smoke-test.sh` | Basic local API smoke test |
| `integration-test.sh` | Local integration test suite |
| `setup-git-hooks.sh` | Install local git hooks |
| `clawgate` | Small CLI helper for pairing and calling the local ClawGate API |
| `dev-deploy.sh` | Local development deploy helper |
| `support-diagnostics.sh` | Collect local diagnostics for troubleshooting |

All signing flows read `$SIGNING_ID` from `.local/secrets/release.env` (a
Developer ID Application identity); there is no one-time self-signed cert
setup step anymore.

## Maintainer / internal scripts

These scripts are tailored to the maintainer's Host A / Host B setup or release environment. They are useful as references, but they are not part of the normal public setup path.

| Group | Examples |
|------|----------|
| Host A / macmini deploy | `macmini-local-sign-and-restart.sh` |
| Cross-host restart | `restart-hostab-stack.sh`, `restart-macmini-openclaw.sh` |
| Host A / Host B validation | `host-a-host-b-e2e.sh`, `macmini-colocated-e2e.sh`, `federation-e2e.sh`, `verify-cc-observe-e2e.sh` |
| Messaging recovery / tracing | `line-fast-recover.sh`, `line-e2e-trace.sh`, `watch-tmux-delivery.sh`, `watch-observe.sh` |
| Release / packaging | `release.sh`, `release-usual.sh`, `setup-keychain-password.sh` |

## legacy/

`scripts/legacy/` holds the retired self-signed `ClawGate Dev` cert
helpers. **Do not run them.** They predate the 2026-04-10 migration to
`Developer ID Application` signing and would regenerate an unstable
self-signed identity, invalidating TCC permissions. See
`scripts/legacy/README.md` for context.

## Guidance

- If you are just building ClawGate locally, start with `restart-local-clawgate.sh`.
- If you are contributing code, use the tests in this repository instead of the Host A/macmini scripts.
- If you are reading an internal script for reference, treat host names, paths, and signer names as environment-specific examples rather than public requirements.
