## Mandatory Build -> Restart Rule

- After any successful build, do not stop at "build passed".
- Always run restart up to a healthy state before reporting completion.
- Pick the entry point by what the change touches (these are not mutually exclusive — the narrower script is always a valid subset of the wider one):

  | Change scope | Entry point |
  |---|---|
  | Local-only app change (no Host A / plugin / Gateway impact) | `./scripts/restart-local-clawgate.sh` |
  | Change touching Host A, `extensions/openclaw-plugin/`, or the Gateway | `./scripts/post-task-restart.sh` |
  | Release | `./scripts/release-usual.sh` |

- `post-task-restart.sh` restarts both Host A and Host B and internally calls the narrower scripts, so it is always safe to use even for a local-only change — it is just not required.

## Mandatory Release Flow Rule

- Canonical release command for this repo is `./scripts/release-usual.sh`.
- `release-usual.sh` always loads `.local/secrets/release.env` first, then runs `scripts/release.sh`.
- Required vars are fixed: `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_ID_PASSWORD`, `SIGNING_ID`.
- Never borrow release credentials from other repositories.
- If `.local/secrets/release.env` is missing, stop and report instead of improvising.
- Before `--publish`, push the target commit first (`git push origin main`). Release scripts do not push commits.
- If `Error: tag vX.Y.Z already exists` appears, bump `ClawGate.app/Contents/Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`) and rerun. Do not delete existing release tags unless explicitly instructed.
- Post-release verification uses `gh release view vX.Y.Z --repo usedhonda/clawgate` and health endpoints `http://127.0.0.1:8765/v1/health` (local + `ssh macmini` remote).

## Autonomous LINE Policy (Canonical)

- Canonical behavior is defined in `docs/SPEC-messaging.md` (Normative).
- Autonomous LINE notifications are milestone-only: `risk`, `interaction_pending`, and `final`.
- `kickoff` and one-line acknowledgement chatter must not be sent to LINE.
- Interactive choice prompts are advisory-only (`interaction_pending`): send recommendation text to LINE, but never execute `<cc_task>`/`<cc_answer>`.
