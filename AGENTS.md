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
- Post-release verification uses `gh release view vX.Y.Z --repo <owner>/<repo>` and health endpoints `http://127.0.0.1:8765/v1/health` (local + `ssh <remote-host>` remote).

## OpenClaw contract hub

- OpenClaw ecosystem contracts are normative in the `oc-general` repository under `docs/contracts/`. In particular, review:
  - `event-contract.md`
  - `runbooks/delivery-routing.md`
  - `runbooks/clawgate-channel-routing.md`
  - `ws-event-contract.md`
- Before changing channel routing, event delivery, or WS RPC flows, confirm the relevant contract and runbook is satisfied.

## LINE critical files and mandatory verification

- `ClawGate/Adapters/LINE/LINEAdapter.swift`
- `ClawGate/Adapters/LINE/LINEInboundWatcher.swift`
- `ClawGate/Adapters/LINE/LineSelectors.swift`
- `ClawGate/Adapters/LINE/Detection/*.swift`
- `ClawGate/Automation/AX/AXActions.swift`
- `ClawGate/Automation/AX/AXQuery.swift`
- `extensions/openclaw-plugin/src/outbound.js`
- `extensions/openclaw-plugin/src/gateway.js`
- `extensions/openclaw-plugin/src/client.js`
- `extensions/openclaw-plugin/src/channel.js`

- When any of these are changed, run validation suitable to the surface (`swift test` for app-side changes and manual send/receive checks where line behavior is touched).
- Do not perform unrelated refactors with line-critical changes.

## Gateway autonomous pendingQuestions invariant

- In autonomous processing changes, preserve: stale `pendingQuestions` entries must not keep `interaction_pending` suppression alive indefinitely.
- `detectInteractionPendingFromCompletion` must not treat a stale pending entry (older than 10 minutes) as `interaction_pending` when no current evidence exists.
- If there is no active evidence (`waitingReason` or `parsedHasOptions`), stale entries should be removed.
- Regression check: after a question is resolved and 10+ minutes pass, completion events should not stay suppressed.

## Autonomous LINE Policy (Canonical)

- Canonical behavior is defined in `docs/SPEC-messaging.md` (Normative).
- Autonomous LINE notifications are milestone-only: `risk`, `interaction_pending`, and `final`.
- `kickoff` and one-line acknowledgement chatter must not be sent to LINE.
- Interactive choice prompts are advisory-only (`interaction_pending`): send recommendation text to LINE, but never execute `<cc_task>`/`<cc_answer>`.

## Feature disable/delete/revert safety — P0

- Do not disable, remove, or revert a working feature without explicit user instruction.
- Do not neutralize behavior by setting disable flags to zero, toggling booleans off, or commenting out active code as an ad-hoc workaround.
- If behavior is broken, correct it instead of turning it off; escalate to user if correction requires waiting or direction.

## Session deferral prohibition — P0

- Do not propose stopping, pausing, deferring completion, or ending work on your own.
- If work is blocked, continue with the next safe action and user-visible progress until user-authorized stop/review.

## Truth-first verification — P1

- When the correct source exists, do not act on guesswork.
- Resolve by checking the authoritative source first and align implementation to it.

## Architecture understanding requirement — P1

- Before touching connection/configuration/bridge/manifest surfaces, verify the current architecture understanding against repo-tracked references and local architecture docs.
- Confirm how settings and gateway paths are configured in the app before changing related files.
- If a task touches one of these paths, also review impacted data flow and state paths:
  - `ClawGate/Core/Federation/`
  - `ClawGate/Core/BridgeServer/`
  - `ClawGate/Core/Config/`
  - `ClawGate/Core/OpenClaw/`
  - `extensions/openclaw-plugin/`
  - `extensions/clawgate-chrome/manifest.json`
- In completion reporting, include architecture drift status where applicable.

## Remote host operation rules — P0

- Use repository canonical scripts for host-side operations.
- Do not run ad-hoc signing flows; use only approved signing workflows.
- On failure, pause and report; do not attempt local substitutes.
- Do not change signing identity used by the project.
- If a local deployment runbook exists, read it before host-side operations.
- Do not store passwords in shared memory/docs, repo notes, or tracked/public files.

## Public repository privacy boundary

- This repository is public; never include real hostnames, real IP addresses, network IDs, personal names/accounts, or secrets in tracked public files.
- Examples to avoid:
  - Tailscale hostnames (`*.ts.net`), SSH aliases, machine hostnames, or personal host identifiers.
  - Private IPs and Tailscale CGNAT-style blocks.
  - Tailnet/Relay/network identifiers.
  - Personal names/account handles and credentials.
- In examples and comments, use placeholders such as `my-host.example-tailnet.ts.net`.
- Public safety checks include `.gitignore` exclusions plus content scanning in `scripts/security-leak-check.sh`.
