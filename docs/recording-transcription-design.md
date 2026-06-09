# ClawGate Ambient Context Stream Design

> Status: design note only
> Scope: client-side recording, transcription, speaker diarization, and OpenClaw context delivery
> Non-goal: implementation, build changes, release changes, or LINE behavior changes

## Purpose

ClawGate should be able to help OpenClaw understand what is happening around the local client machine. This is not primarily a recording archive feature and not just a local transcription viewer. The feature is an ambient context stream: the client captures nearby speech, turns it into timestamped text, assigns speaker metadata where possible, and sends periodic text deltas to OpenClaw so the agent can reason about the user's current environment.

The important product distinction is:

- Recording can be continuous when the client has power.
- Transcription and OpenClaw delivery are explicitly controlled by a Start/Stop button.
- LINE operation remains server-side and is not part of this feature.

## Architecture Boundary

Existing messaging topology in `docs/SPEC-messaging.md` separates the two hosts:

- Server host: LINE adapter, OpenClaw Gateway, FederationServer, relay behavior.
- Client host: local ClawGate app, FederationClient, tmux/status integrations, local environment.

This design keeps that boundary intact.

The client is responsible for:

- microphone capture
- rolling audio storage
- transcription
- speaker diarization
- optional speaker identity inference
- ambient context delta generation
- queueing and forwarding context deltas toward the server/OpenClaw side

The server is responsible for:

- receiving forwarded ambient context events from the client
- handing them to the OpenClaw side as context
- preserving existing LINE behavior

The client must not operate LINE directly. The server must not receive raw audio by default. The normal payload from client to server is text plus timing and speaker metadata.

## Client-Mode Availability

The feature should only exist in client mode.

Implementation should gate all user-visible controls and all HTTP APIs behind a single runtime role resolver. Do not use a loose LINE heuristic such as "lineEnabled=false means client mode" as the feature contract. The intended condition is:

```text
ambient context stream is available iff runtime role == client
```

Current source note (verified): `AppConfig` defines `nodeRole` and `load()` reads it (`AppConfig.swift:130-132`), but the persistence is asymmetric and broken — `save(_:)` actively calls `removeObject(forKey: Keys.nodeRole)` on every save (`:220`), and `nodeRole` defaults to `.client` (`:53`). So role cannot currently be pinned as `server`; it reverts to `client` on the next save. The same pattern strips `federationEnabled` (`:246`), and the Federation start gate depends on it — so fixing role resolution and clarifying Federation startup are entangled through the same stripping `save()`.

Prerequisite (do not skip): before reviving role persistence, first investigate **why** `save()` strips `nodeRole`. It was removed deliberately; blindly restoring it risks re-introducing whatever motivated the removal (likely a prior incident where role mis-persisted on the server host). Restore persistence only after that cause is understood. Otherwise the UI could show recording controls on the wrong host.

Recommended behavior:

- Client mode: show the Context Stream UI and allow local capture/transcription.
- Server mode: hide the UI, omit the option from settings, and return `403 client_only_feature` for direct API calls.

## Recording vs Context Stream State

Treat recording and context streaming as separate states.

### Ambient Capture

Ambient capture is local audio capture into a rolling buffer.

- Starts automatically only in client mode when AC power is available.
- Stops or does not auto-start on battery by default.
- Stores local chunks under Application Support, not inside the repository.
- Does not imply that transcription is running.
- Does not imply that anything is being sent to OpenClaw.

Suggested storage root:

```text
~/Library/Application Support/ClawGate/ambient-context/
```

Suggested audio layout:

```text
ambient-context/
  rolling/
    YYYY-MM-DD/
      chunk-000001.m4a
      chunk-000002.m4a
      chunks.csv
  sessions/
    <session_id>/
      audio/
      transcripts/
      diarization/
      delivery/
```

Suggested defaults:

- audio chunks: 10 minutes
- chunk overlap for ASR: 3 seconds
- rolling retention: 6 hours
- saved sessions: retained until explicit deletion

### Context Stream

Context Stream is the active transcription and OpenClaw delivery session.

- Starts when the user presses `Start Context Stream`.
- Stops when the user presses `Stop Context Stream`.
- While active, the client transcribes new audio chunks and emits OpenClaw context deltas.
- While stopped, the client may continue recording, but does not transcribe or deliver new deltas.
- The user can later choose a recorded time range and run backfill transcription if needed.

The UI should make the separate states visible:

- `Capturing`
- `Transcribing`
- `Streaming to OpenClaw`
- `Queued`
- `On Battery`
- `Client Mode Only`
- `Speaker Identity: calibrated | uncalibrated | uncertain`

## Transcription Pipeline

Decision: ClawGate builds its **own** capture/ASR/diarization stack (whisper.cpp + pyannote + rolling buffer). It does not consume an external transcription app (e.g. a separately running voice-recording app on the same Mac). Trade-off accepted: a second always-on microphone consumer on the host, with duplicated power and disk cost — see Open Items for the coexistence rule that still needs deciding.

Use the same local-first approach as the retreat workflow:

1. Capture or convert audio into ASR-friendly chunks.
2. Run `whisper.cpp` with Metal acceleration.
3. Store raw transcript JSONL.
4. Filter obvious duplicate or repeated loop text.
5. Produce a cleaned Markdown transcript.
6. Align transcript segments to speaker turns.
7. Emit OpenClaw context deltas.

Recommended ASR defaults:

- engine: `whisper.cpp`
- acceleration: Metal
- default model: `large-v3-turbo`
- quality fallback: `large-v3`
- speed fallback: `medium`
- language: explicit when known, otherwise auto-detect
- `max_context: 0`
- `no_speech_threshold: 0.30`
- `entropy_threshold: 2.80`
- duplicate/repetition filtering enabled

Raw ASR output should be append-only. Cleaned transcript files may be regenerated.

## Speaker Diarization

Whisper should not be treated as the diarization engine. Speaker diarization should be a separate local post-processing step.

Recommended approach:

- Run a local diarization pipeline, such as pyannote.audio, against the saved audio window.
- Produce speaker turn artifacts independently from ASR.
- Align ASR text segments to speaker turns by timestamp.
- Keep uncertain speaker assignments explicit.

Suggested diarization artifacts:

```text
diarization/
  speaker-turns.rttm
  speaker-turns.jsonl
  speakers.yml
transcripts/
  raw.jsonl
  cleaned.md
  speaker-aligned.md
```

Speaker labels should begin as stable anonymous IDs:

```text
SPEAKER_00
SPEAKER_01
SPEAKER_02
```

Do not rewrite historical transcript text just because a speaker is later named. Store identity mapping separately in `speakers.yml`.

## User Speaker Identity

If practical, the client should identify whether a segment is likely spoken by the user. This is useful to OpenClaw because the agent can distinguish:

- the user speaking
- another person speaking to the user
- background conversation
- uncertain speech

This must be conservative. A false `self` label is worse than leaving the role unknown.

Suggested roles:

```text
self
other
unknown
```

Suggested metadata:

```json
{
  "speaker_id": "SPEAKER_00",
  "speaker_role": "self",
  "speaker_confidence": 0.91,
  "identity_source": "local_voice_profile"
}
```

Identity rules:

- Only assign `speaker_role: self` above a documented confidence threshold.
- Use `unknown` when confidence is low or audio is noisy.
- Let the user enroll a local voice profile with an `Enroll My Voice` control.
- Let the user correct speaker identity after the fact.
- Store voice profiles locally only.
- Do not send biometric voice embeddings to OpenClaw by default.

## OpenClaw Context Delta

OpenClaw needs enough metadata to understand when the conversation happened and where a text segment belongs in the session. Send transcript deltas every 30 to 60 seconds while Context Stream is active.

The event is context, not a command. It should not be delivered through the LINE adapter and should not be treated as a user instruction by default.

Cross-lane ownership: the receiving context-intake contract lives in `~/projects/openclaw/oc-general/docs/contracts/` (alongside `event-contract.md`, `ws-event-contract.md`, `audio-fanout.md`). That hub is owned by the OpenClaw/oc-general lane — ClawGate cannot finalize the contract unilaterally. Because the agreed sequencing is "contract first," the first deliverable is a contract proposal handed to the oc-general lane, not client code. Note `audio-fanout.md` is the OpenClaw→client audio *out* (TTS) path, the opposite direction from this client→OpenClaw text *in* stream, so this is a sibling contract, not a duplicate; it should still reuse that hub's connect/subscribe envelope conventions.

Suggested event type:

```text
ambient.transcript.delta
```

Suggested top-level payload:

```json
{
  "schema_version": 1,
  "delivery_mode": "ambient_context",
  "session_id": "ctx-2026-06-09T12-00-00Z",
  "sequence": 42,
  "client_id": "local-client",
  "recording_id": "rec-2026-06-09",
  "window_start": "2026-06-09T12:34:00Z",
  "window_end": "2026-06-09T12:35:00Z",
  "timezone": "America/New_York",
  "asr": {
    "engine": "whisper.cpp",
    "model": "large-v3-turbo"
  },
  "diarization": {
    "engine": "pyannote.audio",
    "model": "local",
    "available": true
  },
  "segments": [
    {
      "start_seconds": 2040.12,
      "end_seconds": 2048.76,
      "speaker_id": "SPEAKER_00",
      "speaker_role": "self",
      "speaker_confidence": 0.91,
      "text": "Let's come back to the customer segment first.",
      "source": "audio_transcript"
    }
  ]
}
```

Existing `BridgeEvent.payload` is `[String: String]`. If this stream is implemented through the existing EventBus, either:

- encode the full context delta as a JSON string under a single payload key, or
- introduce a typed event path for structured ambient context payloads.

The design preference is a typed path for long-term correctness, but a JSON-string payload can be acceptable for a first implementation if it is documented and tested.

## Delivery Path

Decided path (Gateway WS, not Federation):

```text
Client capture/transcription
  -> ambient.transcript.delta
  -> Gateway WS (existing ClawGate connection: connect / sessions.messages.subscribe envelope)
  -> server-side OpenClaw context intake
  -> OpenClaw agent context
```

ClawGate is already a sanctioned Gateway WS consumer (`clawgate` in `oc-general/docs/contracts/audio-fanout.md`), using `connect`, `sessions.messages.subscribe`, and `chat.send` over event-contract v3 (port 18789). Ambient context delivery rides this proven connection by adding one new event type, reusing the existing connect/subscribe envelope conventions (`operator.read`/`operator.write`, `sessionKey`) rather than inventing a parallel scheme.

Do not route ambient context through the FederationClient/FederationServer path. That cross-host ClawGate-to-ClawGate channel is gated on `cfg.federationEnabled`, which is `false` by default and is stripped on every `ConfigStore.save(_:)` (`AppConfig.swift:72`, `:246`), so it is dormant under normal config. Reviving a dormant transport and adding a server-side relay hop is strictly more work and risk than extending the live Gateway WS path. (An earlier draft's delivery diagram contradicted this section by routing through Federation; that contradiction is resolved here in favor of the Gateway WS path the prose already required.)

The implementation must not reuse `/v1/send`, because that endpoint represents an intentional message send through an adapter. Ambient context is not a LINE message and not a user instruction. It must be a separate event so OpenClaw ingests it as environmental context, never as chat text or a command.

## Ordering, Ack, and Retry

Each active Context Stream session should maintain a delivery cursor.

Required keys:

- `session_id`
- `sequence`
- `window_start`
- `window_end`

Reliability behavior:

- Persist outbound deltas locally before sending.
- Server/OpenClaw should ACK accepted `session_id + sequence` values.
- Client should retry unacked deltas in order.
- Receiver should deduplicate by `session_id + sequence`.
- If offline, queue locally and replay in order after reconnect.
- If the transcript is regenerated, use a new `revision` value instead of mutating already-acked deltas silently.

Suggested local queue layout:

```text
delivery/
  pending.jsonl
  acked.jsonl
  failed.jsonl
```

## Local APIs

These APIs are implementation guidance for the client app. They should be client-only.

```text
GET  /v1/ambient/status
POST /v1/ambient/capture/pause
POST /v1/ambient/capture/resume
POST /v1/ambient/stream/start
POST /v1/ambient/stream/stop
GET  /v1/ambient/sessions
GET  /v1/ambient/sessions/{session_id}/transcript
POST /v1/ambient/sessions/{session_id}/transcribe
POST /v1/ambient/speakers/enroll-self
PUT  /v1/ambient/speakers/{speaker_id}
```

Server-mode behavior:

```json
{
  "ok": false,
  "result": null,
  "error": {
    "code": "client_only_feature",
    "message": "Ambient Context Stream is only available in client mode.",
    "retriable": false
  }
}
```

## UI Guidance

Add a client-only Context Stream surface rather than mixing this into LINE settings.

Recommended controls:

- Start Context Stream
- Stop Context Stream
- Pause Capture
- Resume Capture
- Enroll My Voice
- Review Speakers
- Open Session Transcript

Recommended status fields:

- capture state
- transcription state
- delivery state
- queue length
- current session id
- current transcript window
- speaker identity calibration state
- battery/power policy state

The UI should never imply that raw audio is being sent to OpenClaw if only transcript deltas are sent.

## Privacy and Safety Rules

- **Hard requirement (non-negotiable): the menu bar must let the user stop and resume capture at any moment, and must make "recording in progress" visible at all times.** Always-on capture on AC power is allowed only on top of this control. If the menu bar control is unavailable, always-on capture must not run.
- Store raw audio locally by default.
- Do not send raw audio to OpenClaw unless a separate explicit feature is designed and approved.
- Do not send biometric voice embeddings to OpenClaw.
- Keep speaker identity confidence visible in local metadata.
- Do not label a speaker as `self` unless confidence is high.
- Let users stop Context Stream without stopping local capture.
- Let users pause capture entirely.
- Use local retention for rolling audio so always-on capture does not become an unbounded archive.

## Implementation Pointers

Relevant existing files:

- `docs/SPEC-messaging.md`: current server/client topology and event model.
- `ClawGate/Core/EventBus/EventBus.swift`: in-memory event buffer and payload shape.
- `ClawGate/Core/OpenClaw/OpenClawWSClient.swift`: the live Gateway WS client (connect / subscribe / send). This is the delivery transport for `ambient.transcript.delta`, per the Delivery Path decision.
- `ClawGate/Core/OpenClaw/OpenClawModels.swift`: Gateway WS message/event model shapes to extend for the new event type.
- `ClawGate/Core/Federation/*`: **not the transport for this feature** — listed only for context. `FederationClient`/`FederationServer` are dormant (gated on the off-by-default, save-stripped `federationEnabled`). Do not build ambient delivery on them.
- `ClawGate/Core/BridgeServer/BridgeRequestHandler.swift`: route registration and threading model.
- `ClawGate/Core/Config/AppConfig.swift`: `nodeRole` (note the broken save persistence at `:220`), LINE, and OpenClaw endpoint config.
- `ClawGate/UI/MenuBarApp.swift`: top-level app UI surface.
- `ClawGate/UI/SettingsView.swift`: settings patterns and config persistence.

External contract references checked for this design:

- `~/projects/openclaw/oc-general/docs/contracts/event-contract.md`
- `~/projects/openclaw/oc-general/docs/contracts/ws-event-contract.md`
- `~/projects/openclaw/oc-general/docs/contracts/audio-fanout.md` (confirms ClawGate is a sanctioned Gateway WS consumer; opposite-direction audio-out path)

Missing expected reference:

- `memory/reference_architecture.md` is referenced by project instructions but is not present in this checkout.

## Acceptance Criteria

The design is ready for implementation when it answers these questions without additional product interpretation:

- Which host records audio?
- Which host operates LINE?
- When does recording happen?
- When does transcription happen?
- When does OpenClaw receive text?
- How does OpenClaw know the time window for each text segment?
- How are speaker turns represented?
- How is the user speaker identified without overclaiming?
- How are offline delivery and duplicate events handled?
- Which existing ClawGate files should an implementer inspect first?

## Open Items

These are unresolved and must be settled before or during implementation:

- **Microphone coexistence**: ClawGate runs its own always-on capture while another voice-recording app may also hold the mic on the same host. Decide the coexistence rule (mutually exclusive capture, or tolerated duplication with bounded power/disk cost).
- **`nodeRole` strip cause**: `save(_:)` deliberately removes `nodeRole`. Investigate why before restoring persistence (blind revival risks re-triggering the original reason). See Client-Mode Availability.
- **pyannote runtime weight**: a resident Python/torch diarization process vs the 30–60s delta cadence — confirm the per-window diarization latency is acceptable and the footprint is tolerable on a client Mac.
- **Retention / privacy concrete values**: rolling retention (default 6h), chunk size, and third-party-audio handling need final numbers and a consent posture, not just defaults.
- **Context-intake contract (cross-lane)**: the OpenClaw-side intake contract is owned by the oc-general lane and must be coordinated there before client delivery is testable.

## Non-Goals

This document does not implement:

- microphone permission handling
- AVFoundation capture
- whisper.cpp integration
- pyannote setup
- OpenClaw Gateway context-intake RPC
- UI changes
- release or restart workflow
- LINE adapter changes
