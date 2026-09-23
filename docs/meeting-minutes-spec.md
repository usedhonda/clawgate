# Meeting Minutes — Contract Spec

Normative contract for the meeting record, the minutes request envelope, and
the reply the client will accept. Public-safe: this document must never contain
real hostnames, IP addresses, network ids, personal names/accounts, or secrets.

## Operating rule

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

The Minutes tab can take an explicit start/end range from that archive and
create a manual meeting. Before it is saved, selected archive chunks are
trimmed to the chosen interval and pinned with an index under that meeting.
A separate `transcript.json` is
generated from their audio. That transcript takes precedence over ambient
`raw.jsonl` for this meeting. Pinned audio expires after 30 days; the meeting
record, transcript, and minutes remain. The existing recording start/stop
control is unchanged. Deep recognition runs through the one-off Whisper CLI,
not the resident live-stream server, so it cannot terminate that server. The
calendar adapter reads scheduled events through the locally installed Google
Calendar CLI. It enumerates authenticated accounts and each account's
calendars, follows all pages, and rejects partial results rather than silently
omitting meetings. Only events overlapping retained microphone audio are
suggested; this does not assert attendance. The tab offers the CLI's Google
account manager. Without authorized calendar access, the explicit date range
remains available. Per-utterance
speaker-name corrections persist across retranscription only when stream,
utterance text, and timestamp still match; uncertain matches remain unnamed.
There is no cross-utterance voice matching yet.

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
- **Open meetings are closed on startup**, using the record's own last write as
  the last sign of life. An app restart mid-call must not leave a range that
  grows forever.

Read back over HTTP with `GET /v1/ambient/meetings` (records, newest first) and
`GET /v1/ambient/meeting/transcript?id=<id>` (record plus its segments).

---

## Request envelope

`policyVersion` = `meeting-minutes-v2`. The outbound message is the universal
prefix, a blank line, then the envelope as JSON — never string-concatenated with
a delimiter, so transcript text cannot break out of the data section.

```
{ policyVersion, requestId, meetingId,
  startedAt, endedAt,          // ISO8601 in the meeting's own zone
  timeZone, title, conferenceCode,
  participantsSeen: [String],
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

## The one evidence exception: the calendar

The body of the minutes may rest on `segments` only. The calendar may be
consulted for **three things and no others**: the meeting's subject, who was
invited, and the scheduled times.

- Match a calendar entry whose meeting link contains `conferenceCode` first.
- Failing that, match an entry overlapping `startedAt`–`endedAt`.
- Failing both, **do not fill anything in.** A guessed entry is worse than none.

`attendance.present` is who was actually there (`participantsSeen` plus whoever
spoke); `attendance.absent` is invitees who are not in `present`. With no
calendar match, `absent` is empty.

## Reply schema

```json
{ "outcome": "answer",
  "minutes": {
    "title": "…", "summary": "…",
    "topics": [{"heading": "…", "points": ["…"]}],
    "decisions": ["…"],
    "actionItems": [{"what": "…", "owner": null, "due": null, "mine": false}],
    "openQuestions": ["…"],
    "evidence": [{"claim": "…", "segmentIds": ["seg-1"]}],
    "attendance": {"present": ["…"], "absent": ["…"], "calendarEventId": null},
    "language": "ja"
  },
  "contextDecision": {"policyVersion": "meeting-minutes-v2"} }
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

## Storage of the result

`meetings/<id>/minutes.json` (the parsed structure) and `meetings/<id>/minutes.md`
(rendered for reading and copying). Both are regenerable: asking again is
idempotent and overwrites them. Minutes are deliberately NOT kept in
`~/.clawgate/logs/log.json`, which truncates to its most recent entries.

## Scheduling

Minutes are requested once, `MenuBarApp.minutesAfterCallSeconds` (90s) after the
call ends — long enough for the final audio chunk to close and be transcribed.

The request **waits its turn**: it never preempts a Log question or scene
naming. While the summon slot is busy the state stays `pending` and it retries,
at most `PetModel.minutesMaxAttempts` times, before failing with a reason the
owner can act on by asking again.

Autonomous LINE delivery is out of scope: `docs/SPEC-messaging.md` keeps
autonomous notifications to milestones, and finished minutes surface in the app.
