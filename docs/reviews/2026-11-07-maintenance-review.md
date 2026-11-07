# ClawGate maintenance review — 2026-11-07

## Baseline and scope

Reviewed ClawGate main at `1174c9b78a74fab56d5a8c710a7ee613ad792cb6` against
OpenClaw's latest stable release available during this review,
[`v2026.11.1`](https://github.com/openclaw/openclaw/releases/tag/v2026.11.1),
release commit `4ffdd2047d192dd65554de3c8c46c0e0197c6e2a` (published November 5).
The reviewed ClawGate baseline had a successful GitHub Actions run. The earlier
notification-timeout/recovery PR was already merged; this change does not
reapply it.

The review covered the native HTTP bridge and federation admission, tmux
monitoring, the OpenClaw channel and telemetry plugins, the Chrome extension,
public documentation, diagnostic collection, and the repository leak guard.
It is not a complete proof of absence of vulnerabilities, a Git-history secret
scan, or a live production acceptance test.

## What ClawGate should own

Keep the macOS-specific responsibilities here: the desktop companion, local
capture and display, Accessibility operations, browser observation, and tmux
session facts. OpenClaw should own agent execution, session storage, resolved
credentials, and channel dispatch policy. Integrate through documented host
APIs rather than private store files or guessed runtime properties.

An upstream Gateway connection and availability of custom Gateway features are
separate facts. Ambient ingest, retained-meeting execution, and several mailbox
and messaging contracts require explicitly compatible host capabilities. Keep
those capability checks and dedicated connections intact; do not advertise
universal compatibility merely because protocol version 4 can be negotiated.
See [the compatibility review](../openclaw-compatibility.md) for the concrete
API and feature matrix.

OpenClaw describes its plugin APIs as experimental and asks authors to pin and
test the host versions they claim to support. This review uses an exact tagged
source baseline, not a moving `main` checkout as a compatibility promise:
[SDK stability guidance](https://docs.openclaw.ai/plugins/sdk-overview).

## Changes and rationale

### Native HTTP admission

The previous browser check covered POST only. Reads can disclose private data
and the Gateway bootstrap credential, while PUT changes session permissions.
The updated admission applies before request-body accumulation and covers all
methods. It rejects ordinary web origins, browser fetch/navigation metadata,
malformed extension origins, and Host values that do not identify the bridge.
The latter closes the Origin-less DNS-rebinding path. Valid unpacked Chrome
extension origins remain supported because their IDs vary across installations.

The handler now caps bodies at 1 MiB and gives incomplete bodies a 15-second
deadline, including chunked requests. Rejections free buffered data and close
the connection after the response. The federation upgrade uses the same
browser/Host checks and matches `/federation` exactly. Configured-bearer
federation still permits authenticated LAN peers; tokenless federation uses
the ordinary source-IP filter. Bootstrap credentials are returned with
`Cache-Control: no-store`.

Message/conversation limits are clamped to 0…200 at HTTP/federation boundaries
and before adapter calls. Negative values previously reached Swift `prefix` or
`suffix` and could terminate the app. Stats day limits are bounded to 0…90.

This preserves the existing source-network policy. It does **not** turn the
CGNAT source-address check into device or user authentication. The API remains
privileged and needs firewall/tailnet ACL isolation. Custom DNS aliases must
match a recognized local name; IP literals, localhost, kernel/Bonjour names,
and the resolved Tailscale name are supported. A public reverse proxy is not a
safe way to expose this service.

### OpenClaw integration and command execution

The channel's tmux working-directory lookup interpolated a target into a shell
command. It now invokes tmux with an argument array, so metacharacters remain
literal target data. A synthetic executable regression verifies both the exact
arguments and absence of shell side effects.

Inbound session recording previously looked for `runtime.config.storePath`,
which is not the supported runtime contract, and silently skipped recording
when it was absent. The plugin now asks the host's session path resolver for
the owning agent's store before calling the host's inbound-session recorder.
Default-account resolution also returns the effective account ID and excludes
null/array values from account discovery.

The optional telemetry plugin omitted the HTTP route `auth` field. OpenClaw
v2026.11.1 rejects that registration; this is a concrete current-host loading
failure, not evidence that the latest host exposed an unauthenticated route.
The route now declares `auth: "gateway"`, exact matching, and handled responses.
Authentication and resolved SecretRefs stay with the Gateway, replacing the
plugin's obsolete raw-token comparison. The host's explicit unauthenticated
mode remains an operator opt-out. Source:
[tagged route registrar](https://github.com/openclaw/openclaw/blob/v2026.11.1/src/plugins/registry-registrars-network.ts).

Telemetry bodies have a 1 MiB/10-second bound, at most 1,000 samples, and at most
eight concurrent requests. Validation prevents malformed values and multiline
health strings from being interpolated into diary context. Serialized diary
writes fix simultaneous batches bypassing the movement/time throttle. The
in-memory dedup store is capped at 10,000 IDs and expires entries on access,
without an import-time interval that can outlive plugin reload.

### Tmux responsiveness and resource use

Unresolved panes previously triggered a fresh `ps -A` subprocess and a complete
process-table parse for each pane. The poller now lazily loads one indexed
snapshot per poll and reuses it only within that poll. Twenty unresolved panes
therefore require at most one process-table launch instead of twenty. Known
pane titles/commands require none. Fresh snapshots on the next poll preserve
process-exit and PID-reuse behavior. This is a verified launch-count reduction,
not a claim about measured CPU or battery savings on a production Mac.

Tmux commands also waited for exit before draining output. A wide capture could
fill the stdout pipe while the parent waited for the child to exit. Both streams
are now drained while the child runs. A regression emits 256 KiB to each stream
and verifies complete, separate output. Prompt text is no longer copied into
the direct poller's classification diagnostic.

### Chrome delivery and recovery

The legacy passive queue could run two flushes concurrently and POST the same
observation twice. It now shares one flush, preserves new entries added while a
request is pending, and permits at most one immediate batch of new captures.
An uncertain item is retained for existing later retry triggers, not immediately
resent in the same flush. A newer sidebar observation is not cleared by an older
request completing.

Bootstrap and poll fetches previously had no deadline and could leave
`pollInFlight` set forever. Bootstrap/poll JSON reads, popup connection checks,
and legacy capture uploads now use ten-second deadlines and refuse redirects.
Cleanup releases polling state and schedules recovery; late bootstrap responses
cannot update credentials. The independent durable Hub outbox was preserved.
Six new regressions run VM-loaded production worker code with controlled
responses and clocks; no live page, message, or personal observation is sent.

### Public repository and diagnostics

The leak guard's own denylist embedded personal environment identifiers. It now
matches generic shapes and emits only path/line information, not the matching
secret text. It rejects local runtime/credential paths, covers additional
provider-key formats, and skips binary loading into shell strings. Its own
regressions verify redaction. Current tracked-text scanning found no additional
live credential that can be declared compromised; the scan does not inspect
all historical commits or external release artifacts.

Support diagnostics now use a unique owner-only directory and file, collect
process IDs/executable names without command arguments, use literal trace
matching, impose network deadlines, and work without developer utilities such
as ripgrep. Diagnostic files can still contain
sensitive operational information and should be reviewed before sharing.

README and setup instructions now reflect the built-in tmux poller, retired
remote-access settings, separate Gateway/bridge endpoints, optional Hub audio
transfer, and actual SDK requirements. The former setup instructions required
cc-status-bar and a general config-write endpoint that are no longer part of
the running architecture.

The bundled OCRAD.js artifact was byte-matched to an exact upstream revision.
Its GPLv3 license and source/build references are now included alongside the
unchanged JavaScript. The root MIT license does not replace this component's
license. See [vendored provenance](../../extensions/clawgate-chrome/vendor/README.md).
This attribution repair does not claim a legal review of combined release
packaging or fulfillment of every corresponding-source distribution obligation.

CI now checks every JavaScript file individually (the old multi-file
`node --check` invocation checked only one), runs Chrome and telemetry
regressions in addition to the main plugin tests, pins its Node test version,
and gives the workflow read-only repository permissions.

The full macOS suite exposed a timing race in an existing pre-acknowledgement
event test: a 50 ms sleep competed with a test-only 100 ms reply watchdog.
That event-correlation case now uses the production deadline and waits for
main-queue event processing before asserting, keeping every original assertion.
The dedicated short-watchdog test and production timeout behavior are unchanged.

## Verification and runtime boundary

Deterministic checks are recorded in the PR and its exact-commit CI result:

- Full OpenClaw channel plugin suite, including literal tmux arguments, account
  resolution, and inbound session recording.
- Full Chrome extension suite and optional telemetry plugin regressions.
- Leak-guard self-tests and the full tracked-file scan.
- Support-diagnostic permissions and process-argument privacy regression.
- macOS build and full Swift suite, including embedded HTTP admission/body tests
  and tmux process/output tests, through GitHub Actions.

The editing environment is Linux and has no macOS Accessibility, microphone,
LINE Desktop, installed browser extension, signing credentials, or live Gateway
runtime. No host was restarted or deployed and no external message was sent.
A CI build does not satisfy the repository's canonical build/restart/live-health
contract for deployment. Use the canonical restart script for the affected
host/plugin paths and verify fresh traffic before promoting the candidate into
an active installation. Preserve existing signing identities and private
runtime manifests.

On a fresh installation, hostname discovery may still be warming when the first
MagicDNS request arrives. Use an IP literal or retry after discovery; do not
weaken Host admission to accept an arbitrary DNS alias. Tmux subprocesses now
drain pipes safely but do not yet have a general process-execution deadline.

## RepoFix follow-up: reuse and CI consolidation

The explicitly requested follow-up reuses this PR's verified code review and CI
instead of recreating the same patch. Independent dependency, lifecycle, and
test-reduction findings are published in focused RepoFix PRs.

The previous `line-smoke` job repeated a subset of the full `swift-test` suite
and the already executed `outbound.test.js` cases. Those Node tests mock the
transports and have no macOS-only operation. Its second macOS checkout/build
does not add a distinct runtime or oracle. Keep the check name as a small Ubuntu
gate that requires successful full Swift and JavaScript jobs, including rejecting
failed, skipped, or cancelled prerequisites. This removes one duplicate Swift
subset run and one duplicate outbound run on LINE-related changes. Mac test
jobs for that path decrease from two to one; no claim is made about a measured
wall-clock or billing reduction.

For this PR relative to main: Swift cases 1,207 to 1,225 (19 added, one permissive
GET-origin case replaced); plugin 190 to 193; Chrome 47 to 53; telemetry 0 to 10;
diagnostic Python regression 0 to 1. Existing security and behavior cases are
retained. The separate test-consolidation PR records its own reductions and
preserved input vectors.

The model audit also distinguishes a stock-compatible CLI handshake from the
custom per-request `chat.send` fields used by Pet Log and minutes. This is
documented in the compatibility matrix without weakening request isolation or
model acknowledgements. The follow-up environment became unavailable mid-task;
GitHub's immutable source reads and exact-commit CI provide the publication and
validation path for these remaining edits.
