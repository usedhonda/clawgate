# Dev Deploy Automation

## Date: 2026-02-08

## Summary

Created one-shot deploy script and lightweight smoke test for daily development cycle.

## Changes

### New Files
- `scripts/dev-deploy.sh` — One-shot build + deploy + OpenClaw plugin sync + smoke test
  - Flags: `--skip-plugin`, `--skip-test`
  - Health polling with 30s timeout
  - Diff-based plugin sync (only copies when changed)
  - Gateway auto-restart via KeepAlive
- `scripts/smoke-test.sh` — Lightweight E2E test (6 tests, ~5s)
  - S1: Health, S2: Auto-pair, S3: Doctor, S4: Poll, S5: Send dry-run, S6: OpenClaw
  - Flag: `--with-openclaw` for OpenClaw gateway log verification

### Modified Files
- `CLAUDE.md` — Updated Build-Deploy Pipeline section to reference `dev-deploy.sh`, updated Quick Reference
- `MEMORY.md` — Added "ClawGate build → OpenClaw recovery" rule

## Verification

- `./scripts/dev-deploy.sh` — Full pipeline: 6/6 PASS
- `./scripts/dev-deploy.sh --skip-plugin --skip-test` — Build+deploy only: OK
- `./scripts/smoke-test.sh --with-openclaw` — Standalone: 6/6 PASS
