# Vision failure diagnostics

`InboundBubbleOCR` keeps delivery state unchanged when a Vision request fails. It
logs the Vision domain/code, atlas dimensions, and requested revision, then
writes a best-effort JSON snapshot to:

`/tmp/clawgate-ocr-debug/latest-vision-error.json`

The parent directory is created lazily. A write failure is logged with only the
write error domain/code and never fails the OCR pipeline.

The JSON is intentionally body-free. Nested `NSError` values are traversed up
to 32 links and at most four unique entries are retained; each entry contains
only `domain` and `code`. Error descriptions, `userInfo`, recognized text,
images, and message bodies are not serialized. Repeated failures with the same
domain/code, atlas size, and revision are throttled to one artifact/log update
per 60 seconds, with no more than 64 keys retained in memory.

The artifact is diagnostic evidence only. It does not alter recognition,
deduplication, LINE routing, or delivery state.

## Partial recognition

Recognition uses native-scale verified bubble crops unless one crop is narrower
than 64 pixels and shorter than 48 pixels. Such a tiny glyph triggers a twofold
atlas scale on the initial, single request, with unchanged revision, languages
and confidence thresholds. Atlases without a tiny crop keep native scale;
when one is present, the entire atlas is scaled together, including larger crops.
The expanded RGBA atlas must fit 16 MiB (the existing recognition-cache byte
budget); otherwise recognition keeps native scale rather than allocating it.
Coordinates are mapped through the scaled placement back to the original crop.
All bubbles must still succeed before any recognition cache entry or watcher
frame state is committed. A missing bubble is never discarded or filled from
previous text. Positioned pixel-bubble fragments retain single-character bodies.

`incomplete_recognition` is a recognition failure, not a quiet or unsupported
frame. The existing watcher failure tracker counts it on both baseline and
subsequent attempts; a successful read clears the streak. Read
`latest-pipeline.json` together with `line-health`: a zero streak
alone is not evidence of successful recognition. Clean canvases remain normal,
and uncertain detection without recognition evidence remains neutral.

## Out-of-process recognition fallback

On some hosts the Vision text recognizer succeeds for the first request of a
process and then fails every later one with `CRImageReaderError` code 1; the
unified log shows `E5RT Error ... create_precompiled_compute_operation ...
(Code: 13)`. Pinning the request to GPU or CPU does not help, and restarting
ClawGate only helps until the next failure. When an in-process request fails,
the atlas is recognized in a short-lived copy of the ClawGate executable
(`--inbound-ocr-helper`), one at a time, and the result fills the recognition
cache. The failing poll still records `vision_error`; the next poll for the
same pixels hits the cache. Delivery, dedup and baseline rules are unchanged.
A helper run can take tens of seconds on such a host; look for
`[OutOfProcessOCR]` lines in the unified log. The temporary atlas is removed
after each run.
