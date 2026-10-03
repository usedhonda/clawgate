# Native audio Hub admission foundation

Status: inactive foundation. No producer loop, source scan, upload or local audio
release is enabled by these types, even when an audio credential is provisioned.
Source capacity and migration checkpoints must be agreed before activation.

## Ownership and scope

The native client owns durable outbound envelopes and validated receipts. The
Hub owner owns historical migration adapters, storage, STT jobs and MCP readers.
L1/L2 ambient summaries are not substitutes for the persisted raw transcript
segments. Six-hour rolling capture and wholesale audio-archive collection are
outside this route. Originals are restricted to selected meeting audio.

## Current local retention evidence

| Source | Existing behavior |
| --- | --- |
| Rolling capture | Six-hour age pruning; excluded from this route |
| General compressed audio archive | Seven-day age pruning; not wholesale admitted |
| Selected meeting audio | Thirty days from audio index modification time |
| Session raw transcripts | Not removed by rolling pruning; explicit deletion |

These are age policies, not byte quotas. The current Ambient/Config code has no
matching native Hub outbox byte budget or preflight free-space gate. Raw append
currently suppresses file errors; archive errors are logged. None of that is
proof of durable Hub delivery or permission for unbounded additional storage.

## Durable outbound metadata

`AudioHubOutbox` requires an explicit positive `maxMetadataBytes`, with no
production default. Its single private state contains a source UUID created
once, immutable request bytes, their SHA-256, source record/revision references,
optional original-file references and the latest acknowledgement. The full
encoded state must fit the supplied cap. Failure preserves pending records;
there is no age-based eviction. Audio bytes are not copied into this state.

Native IDs use `clawgate:native:v1:<source UUID>:<reference/revision digest>`.
The digest uses length-prefixed UTF-8 fields, not an ambiguous delimiter. Old
session/chunk identities remain provenance, never overwritten with different
metadata under an old mirror ID. Retry reuses the exact stored envelope.
The original reference only accepts `meetings/<id>/audio/<file>`; the eventual
file loader must also enforce containment, reject symlinks and verify hash/length
before upload. A path reference alone proves neither bytes nor current coverage.

State writes use private atomic replacement and file/directory synchronization.
An ambiguous storage error prevents further mutation until reopen. A matching
snapshot is required to acknowledge a record. The latest saved receipt is
bounded evidence, not an unlimited historical ledger. Source scan positions
and source-file expiration handling remain activation work; expired or missing
originals must be explicit gaps, never fabricated ACKs.

## Inactive control journal and metadata transport

`AudioHubControlStore` requires a separately supplied positive `maxControlBytes`,
without a default. Its private, atomically synchronized journal records each
source reference/revision as either `enqueued` or `excluded`. `enqueued` means
the immutable envelope was durably admitted to the outbound queue, not delivered
to the Hub. `excluded` records `source_clock_unknown` with no transcript text.
Replay of the same reference/revision is idempotent; revisions are distinct.

The control-state budget is checked before enqueuing. If queue persistence
fails, no admission checkpoint is written. If the queue succeeds but control
persistence fails, the pending bytes survive and control mutation is refused
until reopen. Replay then reuses the same native ID and envelope. A failed gap
write cannot advance a checkpoint or be reported as an ACK. There is no implicit
control-record eviction, receipt success, or source-file scan advancement.

`AudioHubMetadataTransport` sends one persisted `clawgate.audio-transcript.v1`
record only when explicitly called. It checks the source UUID, source/revision
binding and envelope hash, then verifies authenticated source-specific HTTPS
capabilities before posting the unchanged bytes. It rejects redirects, original
references and blob/payload fields; this is not an audio-original uploader.
The request limit is 20 MiB, response streaming stops above 64 KiB, and request
and resource timeouts are 30 seconds. Only a 200/201 response with the matching
metadata receipt returns an acknowledgement. Transport never dequeues by itself,
logs content/credentials, or falls back to Gateway. No background caller exists.

## Receipt boundary

`HubAudioAdmission` validates source/external ID, event UUID, blob SHA-256 and
length, version and positive ingest sequence. Metadata-only transcripts need
storage receipt only and cannot acknowledge an original.

Originals additionally need version-1 processing receipt with committed intent,
a valid job ID, matching original event ID and the advertised pipeline version.
Repeated receipt bindings must preserve event/job/pipeline. Processing state is
a mutable hint and does not prove successful STT. No helper here deletes an
original. The Hub repository's `docs/contracts/stt-jobs.md` remains normative.

## Raw transcript wire

The inactive transcript builder uses `source=clawgate`, `domain=audio` and
`kind=clawgate.audio-transcript.v1`. It preserves every JSON attribute in
`metadata.raw_segment`; `metadata.text` is exactly `raw_segment.text`, without
trimming, summarization or normalization. Hub literal search and full-text
readers use that explicit text field. The envelope has unknown identity, and
speaker labels remain source observations with unverified identity.

`metadata.session_id` uses the `clawgate:session:` namespace;
`source_session_id` retains the original source value. `source_record_ref` is
the exact historical mirror external ID, `clawgate:session:<id>:raw:<line>`,
with a one-based physical line number. `revision_ref` hashes the exact initial
raw line bytes supplied to the builder as `sha256:<hex>`, not re-encoded JSON.
`schema_version=1` and the outbox's persistent `source_uuid` bind the metadata
to this native schema and producer. The future scanner
must preserve those bytes, including the file's line terminator. New native IDs
and immutable envelopes never overwrite the historical mirror's metadata.

`occurred_at` comes only from the raw segment's Unix `capturedAt`. Missing or
invalid clocks produce a body-free control-gap result with
`reason=source_clock_unknown` and `coverage=excluded`, not an event dated at
processing time. The pure builder result is not durable; the control journal
persists that exclusion before returning admission success. It is still not a
delivery ACK or a scan-position cursor. If quota or physical storage prevents
the write, the producer must surface failure and keep scan positions unadvanced.

Absent source privacy flags remain JSON null (unknown); observed flags are
preserved, never replaced with an invented clear state. Downstream authorization
to read unknown-privacy content is a separate consumer policy decision.
Metadata-only transcripts do not create STT jobs; originals do.

## Bounded raw-line reader

`AudioHubRawTranscriptReader` reads one complete physical line with explicit
caller-supplied read and line byte limits. It preserves LF/CRLF and blank lines
as source bytes and counts physical lines. An unterminated tail is held without
advancing the position. It rejects symlinks, non-owned directories/files,
non-regular files, replacement, truncation and invalid line-boundary cursors.
It assumes append-only input; inode/length checks cannot detect an in-place
rewrite on the same inode. No cursor is persisted by this helper, and it does
not parse JSON, enumerate sessions, enqueue records or enable a runtime route.

## Pending activation decisions

Originals use `selected-meeting-original` with explicit source provenance.
Metadata/control byte budgets have no production defaults. The pending runtime
work is scanner orchestration and scan-position persistence, propagation of
source write failures, a contained/hash-checked original loader and chunk upload,
receipt-to-queue orchestration, and explicit original-expiry gaps. The current
control journal handles only transcript clock gaps, not original expiration.

Native start and mirror final checkpoints are not yet agreed. Agree the precise
source reference/revision boundary with the migration owner before activating a
source scan; never infer the boundary from timestamps or mirror record counts.
Historical mirror data is not rewritten or deleted. The mirror owner stops its
route only after source ACK, MCP read and required consumer acceptance. No helper
enables a background scan or delivery route merely by being constructed.
