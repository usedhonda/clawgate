# Meeting Minutes — Contract Spec

Normative contract for the meeting record, the minutes request envelope, and
the reply the client will accept. Public-safe: this document must never contain
real hostnames, IP addresses, network ids, personal names/accounts, or secrets.

## Operating rule

### Repeatable source-to-minutes workflow

The ordinary workflow is **collect sources -> select inputs -> generate or
update -> inspect minutes and citations**. Updating after a meeting is not an
exceptional recovery action. The workspace has one persistent workflow bar,
with a primary `議事録を生成` / `議事録を再生成` action visible on every tab,
including when an accepted document already exists. Source collection opens
the materials tab, where Meet retrieval and local file/text import remain
available. Extraction failures are shown explicitly and not counted as usable
inputs. Generation waits while a source import or explicit Google retrieval
is active. It does not silently wait for, or retry, unavailable sources.

Adding/selecting material does not automatically replace the readable minutes.
The bar reports input changes, the accepted generation time, and reusable part
count. During generation, the previous accepted document remains readable;
the progress banner describes real execution/wait states, not a promised ETA.
`失敗した続きから再開` continues the frozen job. `全パートを作り直す…`
is a separate explicit operation, with confirmation, that discards job
checkpoints but never the accepted document.

At dispatch preparation, freeze speech, unresolved conflicts, calendar metadata
and selected supplemental input in a durable job. Subsequent source refreshes
belong to the next revision; they cannot reset a queued/in-flight generation.
The bounded audio-conflict review may finalize preparation before dispatch.
When input genuinely changes, reuse only the contiguous validated prefix
whose complete envelopes match, ignoring only the request correlation id.
Metadata, policy, citation locators, speech, material content or use-note
changes break reuse at that part. A validated silent result (`nil`) is reusable.
An explicit regenerate with identical input creates fresh parts, not a no-op.
This conservative prefix rule fits the existing sequential durable checkpoint
format; it never treats an unfinished part as complete or reuses a changed
reference result. After new parts are validated, combine in original order and
run the existing grounded overview pass.

### Execution isolation and latency boundary

The target dedicated execution path requires typed `chat.send` flags
`requestLocalContext`, `nonprojection`, and `retainTerminalResult`, all true.
The minutes-only target requests `openai/gpt-6.1-sol` with `thinking=high`;
Pet Log and ordinary-chat defaults remain unchanged. The ACK must confirm
that exact resolution without degradation or fallback, as well as
`isolationApplied` and `nonprojectionApplied`; absent/false confirmation is
an activation failure, not an ordinary-chat fallback. Input must consist of the frozen minutes
request, not preceding conversational turns; output must not project into
ordinary chat/history or messaging channels. Run-id ownership and the existing
grounding validator remain mandatory. The live Gateway rejected the typed
`nonprojection` flag during the activation probe, so this path is **not active**;
the existing working dispatch remains unchanged. Shared summon scheduling is
still sequential, and the existing settling gap remains in force. Input
checkpoint reuse is active independently of this deployment prerequisite.
This change does **not** claim execution isolation, parallelism or a measured
latency multiplier.

The client has inactive typed dispatch/result helpers and an indexed execution
sidecar, `minutes-execution-state.json`. These are not a live route or a
parallel scheduler. Activation still requires matching deployed support;
catalog model availability alone is not successful model execution. The current
Gateway's closed send schema does not admit the three flags, so the existing
working route is not switched to the new helpers.

Model selection is independent of that isolation gate. The existing sequential
part and overview path sends the supported `model`/`thinking` parameters and
validates its own run ID, exact resolution, `degraded=false` and explicit null
`fallbackReason`. An unverified resolution stops that part while preserving its
completed checkpoints; it is not automatically retried on another model. Other
chat and Pet Log model defaults are unchanged. This supported sequential route
does not claim isolated history, retained-result recovery or parallel execution.

The sidecar binds the frozen job fingerprint and exact envelope hash per
index. It imports validated legacy prefix results (including silent results),
reserves at most two live attempts, and saves each immutable attempt key before
dispatch. Out-of-order validated completions retain source order. Only an
explicit retry of a confirmed retryable terminal failure receives a new key;
disconnect, missing results, expiration or an unknown dispatch ACK never
authorize regeneration. Reopening preserves submitting/running attempts for
reconciliation. The retained-result RPC does not contain resolved-model or
isolation diagnostics: after a lost ACK, a terminal answer alone cannot prove
these guarantees. ACK reconciliation must be established before activation.
Private atomic writes, file/directory synchronization, exclusive write locks
and optimistic revision checks prevent a stale writer from replacing a newer
attempt. A persistence error requires reload before further writes. No
execution sidecar modifies or deletes the existing accepted minutes/job.

The next executor design is a dedicated minutes scheduler, independent of the
interactive summon slot, with at most two independent part runs in flight.
Before activating it, prove deployed Gateway concurrent work admission,
request-local delivery, same-device/run correlation, reconnect and retained
result recovery. It requires per-index durable checkpoints (not append-order
completion), per-part retry/idempotency ownership and deterministic ordered
merge. Validate a same-input/same-model comparison including total time,
quality and failure recovery before claiming acceleration. Do not implement
parallel calls by guessing session/subscription behavior or changing models.

Any change to the behavior this spec covers MUST update the corresponding
section in the SAME commit. The `policyVersion` quoted here must equal
`MeetingMinutesPrompt.policyVersion` in code.

## Boundary with the Pet Log pipeline

Minutes are a **sibling** of the Pet Log query pipeline, not an extension of it.
`pet-log-context-v3` freezes its own segment key set and answer schema
(`docs/pet-log-window-spec.md`); minutes need different fields on both sides, so
they carry their own policy version and their own parser. Nothing in this spec
changes the Log wire contract.

What the two share is the transport only: the same `chat.send` summon slot, the
same single-flight admission, and the same connection state.

---

## The meeting record

### Audio retention and retrospective selection

When the existing capture control is on, each finalized microphone chunk is
compressed into a separate 16 kHz mono AAC archive even if context streaming is
off. On macOS 14.2+, the system-output tap likewise archives PC playback as a
separate `system` stream while capture is on. It starts only after the microphone
delivers its first buffer, not concurrently with microphone backend startup.
A failed capture or archive write
is a gap, not evidence of silence. Unselected audio expires after seven days.
The selection UI reports saved mic and system seconds as a share of the chosen
range; missing coverage is never labeled silence.

Calendar time is an anchor, not an audio cut. The app groups retained rough
utterances around the event, notes opening/closing phrases and observed-name
matches to invitees, uses a matching Meet lifecycle when available,
and proposes a conversation range with its evidence. It displays scheduled
and proposed ranges separately. Continuous archived audio alone is not proof
of a conversation. Overlapping events are marked ambiguous until the owner
selects one. The owner may edit the range or clear its calendar association.
The selected event ID and original scheduled range are stored with the meeting;
a matching existing Meet record is reused instead of duplicating it.

The Minutes tab can take an explicit start/end range from that archive and
create a manual meeting. Before it is saved, selected archive chunks are
trimmed to the chosen interval and pinned with an index under that meeting.
A separate `transcript.json` is
generated from their audio. That transcript takes precedence over ambient
`raw.jsonl` for this meeting. Pinned audio expires 30 days after selection;
the meeting
record, transcript, and minutes remain. The existing recording start/stop
control is unchanged. Deep recognition runs through the one-off Whisper CLI,
not the resident live-stream server, so it cannot terminate that server. The
calendar adapter reads scheduled events through the locally installed Google
Calendar CLI. It enumerates authenticated accounts and each account's
calendars, follows all pages, and rejects partial results rather than silently
omitting meetings. Only events with timed RFC3339 `dateTime` endpoints are
meeting candidates; all-day `date` entries are skipped rather than treated as
a meeting covering an entire day. Out-of-office/non-default and transparent
events are likewise excluded from automatic suggestions.
Timed eligible events from the past seven days are combined with stored records
in one workspace. Cards are grouped by local day (newest day first, ascending
start time within each day), independently collapsible, and show day counts.
Search covers titles and names; an optional filter shows only readable minutes.
Confirmed solo appointments with no minutes and no multi-person observation are
hidden, while unknown attendance is never treated as solo. Older stored
meetings remain recoverable through the older-meetings control and are never
deleted. Cards show start/end time, confirmed participants separately from
invitees, state, and truthful `Meet`/`ClawGate` provenance.
Rows without retained `mic` audio are marked "録音なし" and cannot start
automatic transcription; system-output audio alone never counts as microphone
coverage. A calendar entry does not assert attendance. While the Minutes tab is
visible it refreshes every two minutes, so newly finished meetings become
selectable when mic audio is archived.
The manual date range is a collapsed fallback, not the primary path.
The tab uses the CLI's configured account
to start `gog auth add` with Calendar, Drive, and Docs read-only scopes; after a successful
auth command it refreshes candidates in the same view. It does not maintain a
separate Google login or token store. Without a configured GOG
account or authorized calendar access, the explicit date range
remains available. A candidate explicitly selected by the user contributes its
title to the saved meeting. The calendar does not supply transcript or
speaker content. Per-utterance
speaker-name corrections persist across retranscription only when stream,
utterance text, and timestamp still match; uncertain matches remain unnamed.
When backfill replaces the live transcript, an already-observed speaker name is
carried over only on the same audio stream with unambiguous time overlap.
For manually recorded meetings, the live self/other label follows the same
rule. This does not infer a guest's identity from their voice; there is no
cross-utterance voice matching yet.

Calendar candidates and stored records join only by an exact event instance
(calendar ID, event ID, and scheduled start) or a unique conference-code
overlap. Rough audio overlap or a shared event ID alone is not an association.
Selecting an unassociated candidate opens its allowlisted calendar URL; creating
a local meeting is a separate explicit action.

### Meeting workspace material

Google Meet notes are read-only material discovered from authorized Drive/Docs
sources across all document tabs. Nonempty generated notes render as
`Google Meetの生成メモ（発言原文とは別資料）` with HTTPS source links. Meet source segments are
transcript material only when accepted by the material manifest; segments alone
do not count as readable minutes. `available`, `none`, `checking`,
`permissionDenied`, `serviceUnavailable`, `failed`, and `ambiguous` remain distinct states. Cached
notes remain readable if a later refresh fails. Local parsed minutes always take
precedence and retain their stale/partial warning while a retry is pending.

The status item uses left click for the status menu and right click for the main
panel. The menu always includes an explicit Open Main Panel action; recording
controls remain available there.

A meeting is created from the Google Meet call heartbeat
(`POST /v1/ambient/meeting`) and stored at
`ambient-context/meetings/<id>/meeting.json`.

| Field | Meaning |
|---|---|
| `id` | `mtg-<UTC ISO8601 with '-' for ':'>`, same shape as a session id |
| `source` | `meet` (Chrome reported a call) or `manual` |
| `startedAt` / `endedAt` | unix seconds; `endedAt` is the last heartbeat plus the tail |
| `timeZone` | the zone the Mac was in during the call |
| `title` | the Meet tab title with Meet's own decoration removed; `null` when it was only the meeting code |
| `conferenceCode` | the `xxx-xxxx-xxx` code from the Meet URL |
| `participants` | every name whose tile was seen, accumulated across heartbeats |
| `minutesState` | `none` / `pending` / `ready` / `failed` |
| `minutesError` | why the last attempt failed, when it did |
| `calendarID` / `calendarEventID` / `calendarEventStart` / `calendarEventEnd` | optional owner-selected event and original scheduled range |
| `boundaryEvidence` | optional provenance of the proposed audio range |
| `lastHeartbeatAt` | last observed Meet heartbeat, persisted independently of metadata changes |
| `mergedIntoMeetingID` | optional destination for a split Meet fragment; the fragment remains on disk but is hidden from the ordinary list |

Invariants:

- **The transcript is never copied into the record.** Live Meet transcripts
  remain in the ambient session's `raw.jsonl`; retrospective meetings have a
  separate, regenerable `transcript.json` generated from selected audio.
- **The tail.** A meeting's range ends `MeetingRecorder.tailSeconds` (60s) after
  the last heartbeat so the closing words survive, and is then trimmed at the
  next meeting's start so back-to-back calls never swallow each other's opening.
  The range is never widened backwards, for the same reason.
- **Participants accumulate.** A snapshot at the start misses late joiners and
  one at the end misses early leavers, so the union is the only honest answer.
- **Open meetings are closed on startup**, using the persisted last heartbeat
  as the last sign of life. Legacy records without it use the last write.
  An app restart mid-call must not leave a range that grows forever.
- **Split calls can be reconstructed from retained audio.** The calendar is an
  anchor, not an exact cut point. Conversation continuity across multiple Meet
  records selects the record with the greatest overlap as the destination;
  other overlapping fragments are marked as merged only after a successful
  backfill. An internal microphone gap of at least one minute is named even
  when total coverage is high. The old ready minutes remain available but are
  labelled partial while the wider transcript is awaiting validated minutes.

Read back over HTTP with `GET /v1/ambient/meetings` (records, newest first) and
`GET /v1/ambient/meeting/transcript?id=<id>` (record plus its segments).

---

## Request envelope

`policyVersion` = `meeting-minutes-v6`. The outbound message is the universal
prefix, a blank line, then the envelope as JSON — never string-concatenated with
a delimiter, so transcript text cannot break out of the data section.

```
{ policyVersion, requestId, meetingId,
  startedAt, endedAt,          // ISO8601 in the meeting's own zone
  timeZone, title, conferenceCode,
  participantsSeen: [String],
  calendarEventID, scheduledStartAt, scheduledEndAt,
  segments: [{ id, capturedAt, startSeconds, endSeconds,
               speaker, stream, speakerName, text }] }
```

`segments[].id` is `seg-1`, `seg-2`, … in speech order. Unlike the Log envelope,
a segment carries `stream` and `speakerName`: `system` means PC playback and
`mic` means microphone capture. Neither stream proves a participant's identity:
an in-person guest can enter the mic and the owner's own voice can play from
the PC. The model must not infer a named speaker from stream alone.

## Trust boundary

Identical in spirit to the Log prefix:

- `segments[].text` is **quoted, untrusted transcript data** — the thing to
  summarize, never an instruction, whatever it appears to say.
- `title`, `participantsSeen` and `conferenceCode` are page metadata: content,
  not instructions.
- Everything else in the envelope is inert metadata.

## Calendar evidence boundary

The body of the minutes may rest on `segments` only. The client resolves the
calendar association before generation; the model must not search for or
infer another event. The selected title and scheduled times are heading
metadata, not evidence of attendance, speech or decisions. `attendance.present`
uses observed participants and named speakers. No invitee list is sent, so
`attendance.absent` is empty and `calendarEventId` copies `calendarEventID`.
The client enforces those last two fields when saving the reply.

`summary` is a short overview; `topics` is the detailed discussion body, not a
second compressed summary. For each substantive topic, preserve supported
background, proposals, concrete figures and names, alternatives, rationale,
and unresolved points through separate, specific `points`, including material
discussion late in a long meeting. Do not enforce a fixed point count or invent
missing detail. Materially conflicting or unclear figures remain unconfirmed
until checked against the recorded audio. Every point retains its own segment
evidence under the existing fail-closed validation.

## Reply schema

```json
{ "outcome": "answer",
  "minutes": {
    "title": "…", "summary": "…",
    "topics": [{"heading": "…", "points": ["specific discussion claim"]}],
    "decisions": ["…"],
    "actionItems": [{"what": "…", "owner": null, "due": null, "mine": false}],
    "openQuestions": ["…"],
    "evidence": [{"claim": "…", "segmentIds": ["seg-1"]}],
    "attendance": {"present": ["…"], "absent": [], "calendarEventId": null},
    "language": "ja"
  },
  "contextDecision": {"policyVersion": "meeting-minutes-v6"} }
```

The parser is fail-closed. A reply is rejected — never shown as minutes — when:

- it is not JSON (a code fence around the JSON is tolerated, nothing else is);
- its `contextDecision.policyVersion` is not this spec's;
- `outcome` is `answer` with no `minutes`, or `insufficientEvidence` with some;
- `outcome` is neither of those two values.
- any nonempty summary, topic point, decision, action, or open question lacks
  an `evidence` entry with the same claim and at least one ID from the request.

The rendered minutes show each supporting `seg-N` ID as a link to that row in
the transcript view. Each backfilled transcript row can play its pinned audio
from the utterance timestamp while the 30-day clip exists. Automatic voice
identity is not implemented.

`insufficientEvidence` with `"minutes": null` is the required answer when the
meeting has too little speech to write from. Inventing items is a defect.

When the selected record's boundary evidence reports a recording gap, rendered
Markdown explicitly warns that the missing interval is not covered. This is
recording provenance, not a model-generated claim or evidence of silence.

## Storage of the result

`meetings/<id>/minutes.json` (the parsed structure) and `meetings/<id>/minutes.md`
(rendered for reading and copying). Both are regenerable: asking again is
idempotent and overwrites them. Minutes are deliberately NOT kept in
`~/.clawgate/logs/log.json`, which truncates to its most recent entries.

## Scheduling

Minutes are requested once, `MenuBarApp.minutesAfterCallSeconds` (90s) after the
call ends — long enough for the final audio chunk to close and be transcribed.

The request **waits its turn**: it never preempts a Log question or scene
naming. A `pending` record is a durable queue entry, so a busy summon slot,
disconnect, or app restart does not consume a generation attempt. When the
slot is released or the gateway reconnects, queued meetings drain one at a time
with explicit owner requests first. Explicit requests are FIFO by their durable
request timestamp; automatic refreshes and legacy jobs without that timestamp
remain FIFO by meeting end time. An active part is never preempted, and each
request is dispatched at most `PetModel.minutesMaxAttempts` times. A real send failure, parser rejection, or
reply timeout remains a visible `failed` reason that the owner can act on by
asking again; slot waits are never reported as generation failures.
A retry never removes the last accepted parsed minutes: until a replacement
passes the same validation, the accepted output remains readable and is marked
stale or partial with the retry reason. A failed Meet-material refresh likewise
does not erase cached notes.

Autonomous LINE delivery is out of scope: `docs/SPEC-messaging.md` keeps
autonomous notifications to milestones, and finished minutes surface in the app.

### Durable generation and source revisions

Policy v5 chunks long input without dropping utterances. Each validated part,
including an insufficient-evidence part, is checkpointed. All parts must finish
and at least one part must contain grounded minutes before the atomic accepted
bundle is replaced. A retry never removes the previous readable document.
The accepted bundle pins input segments, input fingerprint and unresolved
conflicts, so citations keep referring to the generation-time source revision.
Deterministic assembly preserves the detailed topic points rather than applying
a second lossy summary pass. Generated Meet notes are coverage hints only, never
speech evidence. Numeric/negation differences between aligned similar utterances
remain explicit. At most three retained-audio windows, each at most thirty
seconds, are rerecognized off the UI thread; these are separate evidence, never
silent corrections of the original transcript. Missing audio leaves the
conflict unresolved.

The app bundles the pinned MIT-licensed gogcli helper and its license. Local
bundles use the native architecture; release bundles include both architectures.
Source: https://github.com/steipete/gogcli/tree/v0.42.0

Minutes responses finalize only on an explicit terminal event. A gap between
streaming deltas is not completion and must not parse or discard partial JSON.
The bounded reply watchdog still handles a genuinely missing terminal reply.

A part fails, rather than times out, when the Gateway ends its run without a
reply: a `chat` event in state `error` or `aborted` whose `runId` is the part's
ACK `runId`. A failed or timed-out part is sent again after a backoff (30s, 2m,
5m) while the part still has attempts left; parts already checkpointed are kept
and never resent. The meeting stays `pending` with the reason while it waits and
becomes `failed` only when the part's attempts run out. After a part's reply,
the next part waits `PetModel.minutesPartGapSeconds` (20s): on 2026-09-29 the
Gateway failed every second part sent about six seconds after the first reply.

After a generation of more than one part is accepted, one overview rewrite
(`meeting-minutes-summary-v1`, `MeetingMinutesSummaryPass`) is requested. Its
input is only the parts' overviews with the segments they cited, the topic
headings, decisions and action items; it returns one overview and normalized
due dates. Every overview sentence must cite segments the part overviews
already cited, and topics, decisions and open questions are never rewritten.
A rejected, failed or timed-out rewrite leaves the joined minutes unchanged.
Like minutes, the rewrite finalizes only on an explicit terminal event.

The pause after a reply applies to the shared main session: no minutes or
rewrite request of any meeting goes out within `minutesPartGapSeconds` of the
last reply. A `chat` error on the same session before the in-flight minutes
run has streamed anything is attributed to that run even when its `runId`
differs, because the Gateway reports a failed turn under its own run id.

A job's fingerprint covers its generation input: the policy version, the
segments, unresolved conflict notes, and selected supplemental material text and usage notes. Calendar association, title or
schedule arriving after the first request keep every written part. Once queued,
all remaining parts retain the frozen metadata; updated metadata is incorporated
in the next explicit generation.

Asking again has two forms. Resume (`POST /v1/ambient/meeting/minutes?id=…&mode=resume`)
continues from the checkpointed parts with fresh attempts. Regenerate (no
`mode`) starts a new input revision, reusing only an identical completed prefix
when the source input changed (identical-input reruns start from the first part);
the previous accepted
minutes stay readable until it completes.


### Supplemental materials and workspace exports

The workspace copy action follows the selected tab: minutes (including a
partial label), displayed transcript with time/speaker, or materials including
usage notes and sources. Empty content disables copy; changing tabs or meetings
clears the confirmation.

User-provided PDF, DOCX, TXT/Markdown, PNG/JPEG/HEIC and PPTX materials are copied
into the local meeting directory. OCR/extraction is local. Missing text, limits
and unreadable diagrams are shown as partial/failed, not silently successful.
Each material retains an optional usage note and an inclusion checkbox. Adding,
editing or removing it does not generate minutes automatically.

An explicit regeneration freezes the selected material revision. Long text is
split into uniquely identified fragments with page/slide locators, with bounded
related speech context; transcript coverage remains in independent speech parts.
The complete local input is retained in the job and accepted bundle, and
fragment snapshots preserve citation navigation after an edit or deletion.
Resume retains the frozen material revision. More than 200,000 selected text
characters refuses generation explicitly rather than truncating; originals remain.

`evidence[].materialIds` cites supplemental section IDs separately from
`segmentIds`. Material-only claims are permitted only as topic points prefixed
`【資料補足】`. Summaries, decisions, actions and open questions still require
speech evidence. Terminology corrections cite both speech and material; original
transcripts are unchanged. Unknown citations and material-only decisions are
rejected. The overview rewrite must retain material citations from its input.

Meet retrieval state is separate from the accepted generation's sources:
newly fetched speech may be available but unused. A selected meeting can be
refetched explicitly. API-unavailable failures are reconsidered after 30 minutes;
permission failures require explicit refresh/reconnect. Failed reads preserve
prior content. Fetching materials must not silently regenerate user-edited
supplemental inputs.

### Prompt-only metadata compaction

The model request omits per-segment source URLs and duplicate speaker fields,
and omits zero local-offset placeholders on external transcript lines. Source
IDs, speech text, source type, captured timestamps, locators and meaningful
audio offsets are unchanged. Durable job and accepted bundles retain the
complete source metadata for provenance and navigation. The JSON writer does
not escape slashes. This reduces input overhead without reducing coverage;
it does not itself guarantee a particular model response duration.

### Runtime phase and failure presentation

Pending status distinguishes connection wait, other work/meeting wait,
retry backoff, inter-part gap, conflict audio review, RPC admission,
part generation and overview integration. Dispatch elapsed time starts when
the request is sent; generation elapsed time starts only when its current
owner receives the Gateway run ACK. A late ACK for a released owner cannot
reset the current phase clock. Overview dispatch and integration follow the
same distinction. These clocks are session-local, exclude earlier queue and
retry waits, and are shown separately from completed-part progress; neither
is an end-to-end duration or a completion ETA.
Failures show a concise category and checkpoint-preserving recovery; raw
stored diagnostics are selectable only in an expandable technical section.
Input-range disclaimers belong to app scope UI, not speech-grounded minutes.

### Compact response grounding

The model can cite a factual field by `evidence[].claimRef` instead of repeating
its full text. Supported paths are `summary/N` (split summary sentences),
`topics/N/points/N`, `decisions/N`, `actionItems/N/what`, and `openQuestions/N`.
The parser resolves these references into ordinary full claims before the
unchanged speech/material grounding checks. Invalid paths and conflicting
claim/reference pairs reject the reply. Existing claim-only v6 replies remain
valid for durable and in-flight jobs. Accepted files retain full claim strings,
not the response-only references. This reduces duplicate output text without
omitting meeting detail; measured end-to-end latency improvement is not assumed.
