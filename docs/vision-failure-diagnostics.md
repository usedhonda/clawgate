# Vision failure diagnostics

`InboundBubbleOCR` keeps OCR behavior unchanged when a Vision request fails. It
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
