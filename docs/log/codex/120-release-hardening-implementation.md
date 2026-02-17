# Instruction
Implement the distribution-finalization hardening plan for ClawGate (security, release integrity, notarization runbook, rollback/support guidance).

# What I changed

## 1) Release pipeline hardening
- Rewrote `scripts/release.sh` to use env-based credential contract only:
  - `APPLE_ID`
  - `APPLE_TEAM_ID`
  - `APPLE_ID_PASSWORD`
  - `SIGNING_ID`
- Added strict preflight checks (required commands, env vars).
- Added publish guardrails:
  - release notes file validation with required sections
  - dirty worktree rejection for `--publish`
- Added integrity checks:
  - app codesign verification
  - DMG payload app hash equality check against tested app
  - notarization JSON parsing with `Accepted` status enforcement
  - staple + `spctl --assess --type install`
- Added release manifest output (`ClawGate-release-manifest.json`) including:
  - version, git SHA/ref
  - arch
  - app/dmg SHA256
  - signing authority
  - entitlements hash
  - notarization submission/status/result path

## 2) Secret hygiene docs
- Replaced hardcoded credentials in `.local/release.md` with env-only guidance.
- Added local secret file pattern (`.local/secrets/release.env`) and loading example.

## 3) Runbooks and templates
- Added `docs/release/release-notes-template.md`.
- Added `docs/release/release-notes.md` starter file (placeholder token required to be removed before publish).
- Added `docs/runbooks/release-notarization.md` (15/45/90 minute decision thresholds).
- Added `docs/runbooks/rollback.md`.
- Added `docs/support/triage.md`.
- Added `docs/release-manifest.schema.json`.

## 4) Support tooling
- Added `scripts/support-diagnostics.sh` to generate a support bundle under `/tmp/clawgate-support/`.

## 5) Product docs updates
- Updated `README.md` release section and script inventory.
- Updated `SPEC.md` release pipeline section with new checks and env contract.

# Notes / Risks
- This change intentionally breaks old release behavior that depended on embedded credentials.
- `--publish` now requires a valid notes file and a clean worktree.
