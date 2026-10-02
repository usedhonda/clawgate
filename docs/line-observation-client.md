# Passive client LINE observation

The client observer is independent of the server LINE send/inbound adapter. It
runs only when Settings points to a remote Gateway, and can be stopped through
**LINE 状態監視** in Settings. It never activates LINE, changes window placement,
selects a conversation, scrolls, clicks a notification, or sends a message.

## Acquisition and limits

ScreenCaptureKit enumerates LINE-owned windows separately, including detached
conversation windows. Read-only accessibility structure identifies a history or
sidebar list and editable regions. Only a list that is disjoint from every
composer/search field is cropped for Vision OCR. Unidentified geometry is
unavailable, not an empty conversation. Pixel hashes avoid repeat OCR, which
runs on a utility task. Images remain in memory; audio is not captured.

AX geometry is global top-left points. Image crops are window-relative top-left
pixels; exported OCR boxes are normalized bottom-left window coordinates.
Layout/geometry is checked again after capture. Unknown layouts, a failed
screen-capture preflight (which does not prove an OS denial), minimized/unavailable windows and locked sessions do not trigger
UI recovery or repeated permission requests. The feature requires macOS 12.3;
macOS 14+ uses the screenshot API, earlier supported systems use a bounded
single-frame stream. Historical rows outside the identified content rectangle
are not obtained. Notification previews are separate fragments only when a
LINE header is identified in an already-visible notification window.

OCR spans are **not messages**. No native conversation ID, author, sent time,
read receipt, unread count or send success is inferred. Display names do not
merge conversations. Initial observations have unknown identity and cannot
create individual unanswered-conversation candidates.

## Delivery

The canonical server contract belongs in the OpenClaw contract hub as
`line-observation.md`; do not modify Messenger's platform contract. Client posts
`{observations:[...]}` to `/api/line-observation` at its configured Gateway with
the existing credential. Redirects are refused. Each observation has stable
`line:<producerInstance>:<seq>` identity and distinct opaque device identity.

Snapshots separate sidebar, conversation, notification and machine status.
`ocrSpans` include ordinal, observed text, normalized rectangle and recognition
confidence. Author/direction/sent-time are null and sentAtPrecision is unknown.
Missing surfaces are unavailable; a missing row is not deletion or unread zero.

Only HTTP 200 with `ok:true` and committed `ackedObservationIds` removes those
exact pending IDs. Duplicate delivery must ACK the same ID after server commit.
Unknown, missing or malformed ACKs cannot dequeue. Permanent rejections remain
on disk but do not starve later observations. UnACKed records never expire.

A private disk outbox holds at most 256 MiB. Near capacity it stops text capture,
reports the missing interval, and retries delivery. Changed observations are
queued immediately; unchanged observation status is refreshed every 60 seconds.
Polling is every 2 seconds, reducing to 10 after 30 seconds without change.

## Diagnostics and permission

`GET /v1/debug/line-observation` exposes only machine status, counts and
per-window capture metadata, never OCR text or credentials. Settings shows
capture state, delivery state and pending count, and links to screen recording
settings when the preflight is false. This is an unverified access check, not
proof that macOS denied permission. A 404 server endpoint is independent of
the preflight and is not a successful handoff; records remain pending until
the dedicated server subsystem exists.

Server retention defaults to 30 days under the approved plan, unlike Messenger.
The server dedicated SQLite is the canonical store. Ingestion never triggers
an agent; a separate PCE tick may use state/digest context. Individual unanswered
candidates require confirmed identity, attributed latest inbound, fresh capture
and verified tail coverage, which this initial OCR producer does not assert.
