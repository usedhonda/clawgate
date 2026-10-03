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

OCR spans and body candidates are **not messages**. No native conversation ID, author, sent time,
read receipt, unread count or send success is inferred. Display names do not
merge conversations. Initial observations have unknown identity and cannot
create individual unanswered-conversation candidates.

Visible history AXRows provide explicit UI-item geometry. OCR spans uniquely
inside a non-overlapping item are grouped into a body candidate; geometry alone
does not make that item an attributable or complete message. Ambiguous rows stay
as individual spans. Every candidate retains the source span ordinals, rectangle,
extraction method and `coverage=visible_fragment`. Identical text is not deduplicated
and candidate ordinals are local to the snapshot, not cross-capture message IDs.
Input fields are excluded before OCR; the history and item geometry are rechecked
after capture and are included in the OCR cache key.

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

Schema v1 remains unchanged. Before emitting v2, the client performs authenticated
`GET /api/line-observation/capabilities`. Only a 200 JSON response with `ok=true`,
`supportedSchemaVersions` including 2 and
`bodyCandidateFormat=line-body-candidate-v1` enables v2. Probe failures preserve
v1 delivery. The probe is cached for five minutes per endpoint. Queued observations
are immutable even across schema changes. The server must advertise v2 only after
durable v2 persistence and readback have been verified.

V2 snapshots retain all v1 fields and add `bodyCandidates`. Conversation candidates
carry ordinal, text, source `spanOrdinals`, normalized x/y/width/height,
`extractionMethod` (`ax_history_row`, `ax_text_block` or `ocr_span`) and
`coverage=visible_fragment`; sender/fromSelf/sentAt/displayedTimeText remain null,
sentAtPrecision is unknown. Non-conversation/unavailable snapshots use an empty
candidate array. No stable identity or incoming-message assertion is introduced.

A private disk outbox holds at most 256 MiB. Near capacity it stops text capture,
reports the missing interval, and retries delivery. Changed observations are
queued immediately; unchanged observation status is refreshed every 60 seconds.
Polling is every 2 seconds, reducing to 10 after 30 seconds without change.

## Diagnostics and permission

### Private one-shot comparison

An explicit local `audit-request.json` in the private observation directory can
request one snapshot of the actual app's existing safe capture. It requires an
owner-only 0700 directory, a regular 0600 request, version 1, a UUID requestId,
and an ISO expiry within five minutes. The app consumes the request before
writing a fixed 0600 `audit-result.json`. The result contains observed text and
local history geometry, never screenshots or excluded input fields. It is
private diagnostic material, not a public fixture or a network endpoint.
Without a request no export occurs. Existing debug APIs expose only the result
status, never text. A failed write is reported as failure, not retried silently.

### Independent Hub provisioning

An operator-provisioned `~/.clawgate/hub-provision/line.json` selects independent
Hub delivery. It must be an owner-only regular file (0600, no symlink), at most
64 KiB, with `schema_version:1`, `source:"line"`, a root HTTPS `base_url`, a
source-specific `bearer_token`, and `allowed_domains:["line"]`. The app's audio
source uses a separate `clawgate` descriptor and never borrows LINE authority.
No credential is exposed by configuration/debug APIs. File installation is
separate from implementing this reader; absence is not evidence of provisioning.

Authenticated `/v1/capabilities` must confirm the exact source/domain, receipt
version and limits. Direct storage retains the current v2 observation schema
as opaque metadata; it does not promote body candidates into messages. The fixed
adapter uses `source=line`, `domain=line`, `kind=passive-observation`, the original
observation ID and capture clock. Original queue bytes remain unchanged; derived
envelope bytes are persisted separately once, counted under the same outbox
budget and reused on retries. Missing indexed envelopes fail closed.

Only an HTTP 200/201 matching metadata-only storage receipt can dequeue, with
the latest receipt saved atomically alongside that dequeue. Once independent
delivery is selected, a missing/invalid descriptor or failed request never
falls back to the Gateway. Legacy notification/control actuators are unchanged;
their shutdown requires separate consumer acceptance. Audio-original release is
not implemented by this metadata receipt checker.

`GET /v1/debug/line-observation` exposes only machine status, counts and
per-window capture metadata, never OCR text or credentials. Settings shows
capture state, delivery state and pending count, and links to screen recording
settings when the preflight is false. This is an unverified access check, not
proof that macOS denied permission. A 404 server endpoint is independent of
the preflight and is not a successful handoff; records remain pending until
the dedicated server subsystem exists.

Sidebar and conversation counts, local body-candidate count, negotiated schema,
last observation time and last durable ACK are independent machine diagnostics.
An observation older than 30 seconds is labelled stale. Disabled, locked or
unavailable surfaces clear current counts rather than exposing previous text as
current evidence. Missing/unidentified history stays unavailable.

`capturePerformance` reports the last capture invocation's monotonic wall-clock
milliseconds, screenshot/OCR stage durations and cache hit/miss counters, plus
cumulative stage durations and counters for this process. An unreached stage's
duration is omitted, not reported as zero; inactive capture reports null. These
are observer-specific elapsed times, not CPU utilization. Cache hits reuse OCR
without running recognition again. No timing fields enter the observation wire.
V2 also explicitly supplies unknown identity and empty candidate arrays for
unavailable surfaces; missing history never becomes a confirmed empty thread.

## Visible-content structure (v3)

The client computes `line-visible-content-v1` locally. Original `ocrSpans`
remain unchanged. Where usable AX item regions are absent, closely aligned
adjacent lines form a **visible text fragment**, not a verified message.
Separate columns, large gaps and overlapping/ambiguous blocks do not merge;
repeated text is retained. This cannot recover off-screen history or clipped
glyphs and does not certify a complete bubble.

Small Japanese AM/PM clock badges can be associated with a unique neighboring
multiline fragment only when their geometry, font size and end alignment agree.
Competing associations remain unknown. `displayedTimeText` preserves the OCR
string; `sentAt` stays null with precision unknown. A centered, isolated exact
unread-divider phrase may be retained as an annotation, never as read state or
an unread count. All annotation source ordinals remain traceable to raw spans.

For a structurally identified conversation, matching AX/window-server titles
provide `conversationLabel` with `conversationLabelEvidence=ax_window_title`.
It is an observed display label, not native identity or author. Generic,
disagreeing or unavailable titles remain null. Layout/title evidence is checked
again after capture and participates in cache validity.

V3 candidates retain the v2 fields and add nullable `displayedTimeEvidence`
(`method`, `spanOrdinals`). Snapshot `annotations` contain ordinal, text, source
spanOrdinals, normalized rectangle, kind, evidence and nullable relatedBodyOrdinal.
Kinds are `displayed_time` and `unread_divider`; corresponding evidence methods
are `ocr_clock_badge_layout` and `ocr_centered_divider`. Grouping may use
`ocr_aligned_lines`. Identity/sender/fromSelf stay unknown, tailCoverage false.

Independent Hub delivery selects v3 only if authenticated capabilities advertise
both schema 3 and `line_observation_semantic_format=line-visible-content-v1`.
Otherwise it uses the explicitly supported v2/v1. Missing supported schemas
block independent delivery rather than guessing compatibility. No queued bytes
or IDs are migrated, and no legacy Gateway fallback is introduced. Public
debug output and Settings contain only counts/status; new local extraction and
negotiated delivery are shown separately. V3 storage/MCP/consumer acceptance is
separate from already accepted v2 delivery.

CPU diagnostics additionally measure the thread initiating synchronous Vision
recognition. These are actual thread CPU milliseconds, not wall time, but exclude
Vision's other worker threads/GPU and cannot be called whole-observer CPU or
energy use. Cache-only captures omit the latest OCR CPU sample.

Server retention defaults to 30 days under the approved plan, unlike Messenger.
The existing Personal Data Hub LINE domain is the canonical SQLite store;
this observer does not create a separate LINE database. Ingestion never triggers
an agent; a separate PCE tick may use state/digest context. Individual unanswered
candidates require confirmed identity, attributed latest inbound, fresh capture
and verified tail coverage, which this initial OCR producer does not assert.
