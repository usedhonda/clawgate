# Ambient STT Quality Guide

> Status: implementation guidance
> Scope: local speech-to-text quality for ClawGate Ambient Context Stream
> Non-goal: speaker diarization, OpenClaw delivery, UI design, or LINE behavior

## Purpose

ClawGate Ambient Context Stream depends on speech-to-text quality. The goal is not just to make transcription fast; it is to make the transcript useful enough for OpenClaw to understand the user's current context without being misled by repeated phrases, hallucinated filler, or missing key terms.

This guide captures the current best local STT settings from prior noisy-room transcription work and turns them into a repeatable ClawGate preset.

## Recommended Default Preset

Use a named preset instead of exposing only a model picker.

```text
large-metal-noisy-room-v1
```

Preset values:

```text
engine: whisper.cpp
backend: Metal
model: large-v3-turbo
asr_window_seconds: 300
overlap_seconds: 3
max_context: 0
beam_size: 5
no_speech_threshold: 0.30
entropy_threshold: 2.80
vad: on by default when the silero-v5.1.2 model is provisioned, otherwise off (degrades gracefully)
greedy_decoding: off by default
duplicate_filter: on
internal_repetition_filter: on
contextual_prompt: on when safe
```

Recommended model files:

```text
ggml-large-v3-turbo.bin
ggml-large-v3.bin       # quality fallback when turbo is not enough
ggml-medium.en.bin      # speed-only fallback, not quality fallback
```

## Why These Settings

The quality improvement came from the whole pipeline, not from "use a larger model" alone.

The strongest observed pattern was:

- baseline large settings can still repeat phrases in noisy sections
- `max_context = 0` removes a major source of loop-like repetition
- 5-minute ASR windows are more stable than longer chunks for noisy room audio
- 3-second overlap preserves boundary context without too much duplicate text
- threshold tuning reduces obvious duplicate output without dropping as much useful content as VAD
- duplicate/repetition sidecar filtering catches remaining bad segments

`large-v3-turbo` should be the default because it was both materially better than small-model transcripts and fast enough with Metal on Apple Silicon. The implementation should not downgrade to `medium` purely for speed unless the machine cannot keep up.

## Known Bad Fallbacks

Avoid these as default quality choices:

- `medium.en` as a quality fallback: observed to produce loop-like hallucinations in noisy sections.
- VAD by default: faster, but too lossy for ambient context and still not a complete fix for repetition.
- Greedy decoding by default: worsened repeated hallucinations in noisy samples.
- Long ASR chunks by default: more likely to carry bad context forward and produce repeated text.
- Model-only tuning: changing model size without chunking, context, thresholds, and filtering is not enough.

## Prompting Policy

Use a contextual prompt when it is safe and local:

```text
This is a live room conversation. Expect startup, product, revenue, fundraising,
operations, engineering, and personal-assistant context. Preserve names and
technical terms when heard. Do not invent content for unclear audio.
```

The prompt may include local project names or expected speaker names only if that data is already available locally and is appropriate for the session. Do not send prompts or audio to an external STT service by default.

The prompt is a hint, not proof. Downstream code must still mark the transcript as machine-generated and not quote-safe.

## Output Layers

Keep the STT output layered so quality problems can be audited.

```text
transcripts/
  raw/
    <session>.whisper-cpp-metal-large-v3-turbo.raw.jsonl
    <session>.whisper-cpp-metal-large-v3-turbo.skipped.jsonl
  cleaned/
    <session>.cleaned.md
  aligned/
    <session>.speaker-aligned.md
```

Raw transcript rows should be append-only for a given run.

Skipped rows should explain why a segment was removed:

```json
{
  "reason": "rolling_duplicate",
  "start_seconds": 123.45,
  "end_seconds": 128.90,
  "text": "repeated text..."
}
```

Recommended skip reasons:

- `rolling_duplicate`
- `immediate_duplicate`
- `internal_repetition`
- `zero_audio`
- `manual_redaction`

`zero_audio` is a pre-transcription skip for chunks with no signal at all
(e.g. a muted/disconnected input), based on a whole-chunk RMS check against
an epsilon far below any real audio level. It is not a speech/silence
judgment — that is delegated to Whisper + Silero VAD (`vad` below). A
2026-07-15 incident found real conversation audio measuring
rms 0.005803–0.014562, below what an earlier, more aggressive whole-chunk
RMS threshold (0.015) treated as silence; that threshold silently dropped
real meeting audio before it ever reached VAD and has been removed.

## Quality Evaluation

Do not judge STT quality only by runtime. For ambient context, quality means:

- fewer repeated or looped phrases
- fewer hallucinated confident statements in noisy stretches
- key names and technical terms are preserved more often
- timestamps are stable enough for later speaker alignment
- enough useful content remains after filtering
- output is good enough for synthesis, but not treated as direct quotation

Minimum benchmark set before changing the preset:

- opening or informal section with room noise
- dense technical section
- multi-speaker Q&A section
- low-confidence tail section
- at least one sample with expected names or product terms

Compare each candidate with these counters:

```text
segments_total
segments_kept
segments_skipped
recent_duplicates
immediate_duplicates
internal_repetition_segments
empty_or_near_empty_segments
runtime_seconds
audio_seconds
realtime_factor
```

Lower duplicate counts are good only if useful content is not being thinned out. A preset that removes too much content is not better.

## Acceptance Criteria

A preset can replace `large-metal-noisy-room-v1` only if it satisfies all of these:

- materially reduces repeated phrases compared with the current preset
- keeps or improves useful content density
- does not increase hallucinated confident text in noisy sections
- remains fast enough for the Context Stream cadence
- produces timestamps suitable for diarization alignment
- keeps raw, skipped, and cleaned outputs separate
- preserves the rule that machine transcript is not quote-safe without audio review

## Operational Rule

For ClawGate, STT quality is part of the feature contract. The app should log the active preset name, model, thresholds, chunk length, overlap, and filtering decisions for every session. Without that metadata, later transcript quality problems cannot be debugged.

Suggested metadata:

```json
{
  "preset": "large-metal-noisy-room-v1",
  "engine": "whisper.cpp",
  "backend": "Metal",
  "model": "large-v3-turbo",
  "asr_window_seconds": 300,
  "overlap_seconds": 3,
  "max_context": 0,
  "beam_size": 5,
  "no_speech_threshold": 0.30,
  "entropy_threshold": 2.80,
  "duplicate_filter": true,
  "internal_repetition_filter": true
}
```
