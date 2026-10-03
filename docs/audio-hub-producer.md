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
bounded evidence, not an unlimited historical ledger. Source scan checkpoints
and source-file expiration handling remain activation work; expired or missing
originals must be explicit gaps, never fabricated ACKs.

## Receipt boundary

`HubAudioAdmission` validates source/external ID, event UUID, blob SHA-256 and
length, version and positive ingest sequence. Metadata-only transcripts need
storage receipt only and cannot acknowledge an original.

Originals additionally need version-1 processing receipt with committed intent,
a valid job ID, matching original event ID and the advertised pipeline version.
Repeated receipt bindings must preserve event/job/pipeline. Processing state is
a mutable hint and does not prove successful STT. No helper here deletes an
original. The Hub repository's `docs/contracts/stt-jobs.md` remains normative.

## Pending wire and activation decisions

Proposed transcript kind is `clawgate.audio-transcript.v1`, with original source
capture time and unchanged raw segment attributes, including unverified speaker
labels. Preserve unknown privacy/identity/time fields; do not invent clear
privacy flags or substitute processing time for missing capture time. Originals
use `selected-meeting-original` with explicit source provenance. Exact metadata,
source references, revisions, byte budget, native start checkpoint and mirror
final checkpoint require owner agreement. The mirror owner stops its route only
after source ACK, MCP read and required consumer acceptance.
