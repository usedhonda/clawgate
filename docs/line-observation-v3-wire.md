# LINE passive-observation v3 wire contract

This document is the public producer contract for the LINE passive observer.
It describes observed, visible content only. OCR spans, body candidates, labels,
clock badges, and dividers are evidence fragments; they are not messages,
native conversation identity, authorship, sent time, read state, or delivery
success.

## Hub envelope

One observation is sent as one Hub event. There is no batch form and the complete
JSON envelope is limited to 2 MiB (stricter than the Hub's generic 20 MiB limit).
The outer fields are fixed:

```json
{
  "source": "line",
  "domain": "line",
  "kind": "passive-observation",
  "identity": null,
  "external_id": "line:<producerInstance>:<seq>",
  "occurred_at": "<metadata.capturedAt>",
  "metadata": { "...": "v3 observation" }
}
```

`external_id` is exactly `metadata.observationId`; `occurred_at` is exactly
`metadata.capturedAt`. The producer metadata is:

| Field | Required value/shape |
| --- | --- |
| `schemaVersion` | `3` |
| `platform` | `line` |
| `source` | `clawgate-line-passive-ocr` |
| `producerInstance` | synthetic/opaque UUID-like producer identifier |
| `deviceId` | synthetic/opaque UUID-like device identifier; distinct from producer identity where applicable |
| `seq` | positive producer-local sequence; fixture uses `1` |
| `observationId` | `line:<producerInstance>:<seq>` |
| `capturedAt` | ISO-8601 source capture clock, fixed for this observation and its retries |
| `snapshots` | snapshot array described below |

The producer has no confirmed identity. `identity` is always JSON `null` and
`conversationKey`, `sender`, `fromSelf`, and `sentAt` remain unknown/null.
`sentAtPrecision` is `unknown`; `tailCoverage` is `false`.

## Snapshot and v3 additions

Current snapshot fields and `ocrSpans` remain unchanged. Snapshot ordinals and
candidate/annotation ordinals are local to that snapshot, never message IDs.
Each raw span is retained. On an available conversation, body span references
and annotation span references are disjoint and together cover every raw span
exactly once. A grouped candidate joins source text literally (line breaks are
preserved); grouping does not alter raw spans.

V3 adds these required fields to every snapshot:

* `conversationLabel`: observed display label string or `null`.
* `conversationLabelEvidence`: `null` or
  `{ "method": "ax_window_title", "axObservationOrdinal": 0 }`.
* `axObservations`: array, or `[]`. The permitted observation shape is
  `{ "ordinal": 0, "windowId": "<same snapshot windowId>",
  "attribute": "AXTitle", "value": "<exact label>",
  "corroboratedBy": "SCWindow.title" }`.
* `annotations`: array of objects with `ordinal`, `text`, `spanOrdinals`,
  normalized `x`, `y`, `width`, `height`, `kind`, `evidence`, and nullable
  `relatedBodyOrdinal`.

Only `AXTitle` observations are exported. Source AX and ScreenCaptureKit
titles must match and be rechecked after capture; this is corroboration, never
identity. Labels are capped at 512 UTF-8 bytes. If unknown, label,
label evidence, and AX observations are respectively `null`, `null`, and `[]`.
No other AX attributes, drafts, or input-field contents are exported.

Body candidates retain the current fields and add required nullable
`displayedTimeEvidence`:

```json
{ "method": "ocr_clock_badge_layout", "spanOrdinals": [2] }
```

`displayedTimeEvidence` references the raw spans of a clock annotation whose
`relatedBodyOrdinal` is this candidate's ordinal and whose literal `text`
equals `displayedTimeText`. Otherwise both time fields are `null`. Clock annotations use kind
`displayed_time` and evidence `ocr_clock_badge_layout`. The exact observed
divider phrase may be retained as kind `unread_divider` with evidence
`ocr_centered_divider`; it never asserts unread state (`unreadState` remains
unknown).

Unavailable, non-conversation, or non-current surfaces have no candidates,
annotations, labels, or AX observations. They carry an unavailable reason when
known. V1 and V2 output is unchanged and must not contain these new fields.
Missing any required v3 field makes a v3 producer invalid; a generic Hub store
may preserve unknown metadata, but that is not semantic acceptance.

## Bounds and failure behavior

The legacy limits remain in force: at most 32 snapshots; at most 500 raw spans
and body candidates per snapshot; OCR text at most 4,000 JavaScript UTF-16 code
units; and the 2 MiB single-request cap. V3 additionally permits at most 500
annotations and at most 500 valid, same-snapshot span references across
candidate/annotation references. Clock extraction remains within the existing
4,000 UTF-16-unit text bound and adds no new capacity. Enum strings are exact.

There is no truncation. If a limit would be exceeded, the producer marks the
surface/observation unavailable with reason `observation_limits_exceeded`,
retains pending bytes, and does not fabricate an ACK. A grouped candidate that
would exceed the text limit is split without changing raw spans: AX groups
fall back to raw-span candidates; OCR-only groups stop before the overflowing
line and start another candidate.

The immutable derived envelope is persisted once and retried unchanged. It is
counted with the existing 256 MiB outbox budget; outbox and ACK behavior are
otherwise unchanged.

## Capability and acceptance boundary

The producer may select v3 only when authenticated capabilities advertise both:

```text
schema version 3
line_observation_semantic_format = line-visible-content-v1
```

The future acceptance gate is separate from producer generation: immutable
store persistence, duplicate/conflict handling, MCP page readback, and natural
v3-source ACK must each be proven before Hub semantic acceptance. Chi/consumer
acceptance is a separate gate. Capability negotiation alone is not proof of
any of those downstream behaviors.

## Synthetic fixture

`Tests/Fixtures/line-observation-v3.json` is one public-safe envelope with a
single available conversation snapshot. It uses synthetic identifiers and a
fixed capture time; it contains no personal names, credentials, or real IDs.
