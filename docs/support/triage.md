# Support Triage Guide

Use this guide for inbound failures, slow response, or missing LINE output.

## 1) Collect diagnostics

Run on affected machine:

```bash
./scripts/support-diagnostics.sh [trace_id]
```

Output file is created under:

```text
/tmp/clawgate-support/diagnostics-<timestamp>.txt
```

## 2) Required fields in support ticket

- App version
- Host role (server/client)
- Timestamp (JST and UTC if possible)
- `trace_id` (if visible in Ops Logs)
- Diagnostics file path

## 3) Trace path to verify

For a send path, confirm events in this order:

1. `ingress_received`
2. `ingress_validated`
3. `gateway_forward_start`
4. `line_send_start`
5. `line_send_ok`

For federation client path, also confirm:

- `federation.connecting`
- `federation.connected`
- tmux capture event (`tmux.progress`, `tmux.completion`, `tmux.question`)

## 4) Common failure signatures

- `send_failed`: check error code and message, validate session mode and target project.
- `session_not_allowed`: project mode is not executable on that host.
- no `line_send_ok`: inspect LINE permissions and foreground availability.
- federation disconnected: verify host URL/token and server listener status.

## 5) Escalation

Escalate when any of these occur:

- repeated `send_failed` with same trace_id
- no `Accepted` notarization on a release build
- crash loops after update

Attach diagnostics output and exact reproduction steps.
