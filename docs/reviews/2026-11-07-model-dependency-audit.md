# Model and inference dependency audit — 2026-11-07

This is the model/API portion of the explicitly requested RepoFix review. The
source baseline is `1174c9b78a74fab56d5a8c710a7ee613ad792cb6`.
The existing maintenance review in [PR #8](https://github.com/usedhonda/clawgate/pull/8)
was read first; its gateway security work is not repeated here.

## Outcome

The confirmed change is to provision the resident whisper.cpp server from
**v1.9.5 instead of v1.9.4**. The newer release contains upstream model/VAD
tensor-type bounds checks for CVE-2026-110810. The cloud model IDs used by ClawGate
remain documented by OpenAI, with no retirement notice found for those IDs in
the current deprecations page. They are retained.

This is a dated source and compatibility review, not proof of model access,
inference quality, or compatibility with an uninspected production host.

## Scope and ownership

The inventory covered application and helper source, prompts, agent instructions,
routing/fallback code, configuration, scripts, manifests and lockfiles, tests,
fixtures, examples, CI, and documentation. No environment-file credentials or
private deployment configuration were needed.

ClawGate sends cloud requests to OpenClaw; it does not depend on the OpenAI,
Anthropic, or Google SDKs or call their public inference endpoints directly.
The app's main Swift dependency is SwiftNIO; the separate diarizer helper depends
on FluidAudio. The JavaScript integration packages do not add a provider SDK.
The SwiftNIO security review is a separate change, not part of this server update.

## Cloud model inventory

| Production path | Concrete selection | Fallback and acceptance boundary |
| --- | --- | --- |
| Ordinary chat / channel dispatch | No app-selected provider or model. The host's agent configuration chooses them. | Ordinary `ChatSendParams` carries the session, message, and idempotency key. Host configuration owns provider availability and limits. |
| Pet Log | `openai/gpt-5.6-sol`, `thinking: "max"` | The acknowledgement must confirm the requested model without degradation, or the specifically permitted `openai/gpt-5.6-terra` fallback with degradation and a bounded machine-readable reason. Request-local context and nonprojection checks remain mandatory. |
| Sequential and retained minutes | `openai/gpt-6.1-sol`, `thinking: "high"` | Exact model/effort acknowledgement is required; there is no silent degraded model fallback. The retained path also checks its run/session/fingerprint/binding contract. |

The controlling definitions are in
`ClawGate/Core/OpenClaw/OpenClawModels.swift` and
`ClawGate/Core/OpenClaw/MinutesExecutionTransport.swift`.
The repository's `openai/gpt-6-sol`, `gpt-5.6-flash`, and malformed model strings
used to reject wrong acknowledgements are negative test fixtures, not runtime
defaults. `claude_code`, `codex-cli`, and `@openai/codex` identify terminal
applications; they do not select a model for these requests.

### Provider status, verified 2026-11-07

| Provider catalog ID | Official evidence | Assessment |
| --- | --- | --- |
| `gpt-5.6-sol` | [Model catalog](https://developers.openai.com/api/docs/models/gpt-5.6-sol) documents the model and `max` reasoning effort. | Supported catalog entry; no retirement notice found. Keep the established Pet Log primary contract. |
| `gpt-5.6-terra` | [Model catalog](https://developers.openai.com/api/docs/models/gpt-5.6-terra) documents the model and `max` reasoning effort. | Supported catalog entry; no retirement notice found. Keep the explicitly acknowledged fallback. |
| `gpt-6.1-sol` | [Model catalog](https://developers.openai.com/api/docs/models/gpt-6.1-sol) documents `high` reasoning effort; tool calling requires the Responses API. | Supported catalog entry; no retirement notice found. Keep the minutes contract. The host must choose the appropriate provider API. |

The [deprecations page](https://developers.openai.com/api/docs/deprecations) and
[changelog](https://developers.openai.com/api/docs/changelog) were checked.
Each of these catalog pages documents a 1,050,000-token context window and
128,000 maximum output tokens, with text/image input and text output.
These are provider limits, not a guarantee of remaining context or configured
output limits on a particular OpenClaw installation. The model-specific
ClawGate requests above are text requests; local speech is handled separately.

`openai/` is OpenClaw's provider qualification, and `thinking` is a gateway
field. These are not literal OpenAI wire parameters: the host must resolve the
qualified ID, normalize reasoning effort, and select the provider API.
The official v2026.11.1
[reasoning-effort implementation](https://github.com/openclaw/openclaw/blob/v2026.11.1/packages/ai/src/providers/openai-reasoning-effort.ts)
distinguishes Responses from Chat Completions, including support for `max`.
A supported provider model alone does not prove that a custom host maps the
request correctly. No paid provider calls or account/region-access probes were
made.

The stock v2026.11.1
[`chat.send` schema](https://github.com/openclaw/openclaw/blob/v2026.11.1/packages/gateway-protocol/src/schema/logs-chat.ts)
accepts `thinking`, but its closed shape does not declare `model`,
`requestLocalContext`, `nonprojection`, or `retainTerminalResult`.
Consequently Pet Log and minutes per-request model routing require the matching
host extension even on an ordinary CLI connection. A stock-compatible handshake
does not establish support for these requests. Dropping those fields or changing
a shared session's model would break their isolation and routing guarantees.

There is no provider price table or app-level `max_output_tokens` setting to
update. `PetLogRequestBudget.maxRequestBytes` in
`ClawGate/UI/Pet/PetLogContext.swift` is a 1,000,000-byte UTF-8 request budget,
not a token estimate. Oversized requests fail closed. The host remains
responsible for its tokenizer, prompt overhead, and output allowance.
Changing models on age alone would require new quality, latency, cost, and
host-contract validation; no such substitution is justified by this review.

## Local speech and voice inventory

| Component | Concrete model/API/dependency | Assessment and boundary |
| --- | --- | --- |
| Native transcription | Apple `SpeechAnalyzer` / `SpeechTranscriber` on macOS 26+, `ja-JP`, system-managed model assets | The preferred engine checks locale/model availability. Unavailable/error cases and the app's language-output heuristic fall back to Whisper. No downloadable Apple model version is pinned by the repo. |
| Whisper transcription | `ggml-large-v3-turbo.bin`; Silero VAD `ggml-silero-v5.1.2.bin`; local `whisper-cli` or the optional resident server | Audio/model inference is local. This is not the hosted OpenAI `whisper-1` API. Defaults are in `AmbientStorage.swift`; the model preset keeps Metal, bounded context, and the existing decoding/filter settings. Model weights are unchanged. |
| Resident Whisper server | `scripts/provision-whisper-server.sh`, default v1.9.4 at the baseline; v1.9.5 after this change | See the security finding below. The server has its own binary/dylib directory, separate from the CLI. |
| Speaker diarization / enrollment | FluidAudio 0.15.2, locked to `7f963cdc43ba89c5993654f1e138047d517a818d`; library-managed `FluidInference/speaker-diarization-coreml`, `pyannote_segmentation`, and `wespeaker_v2` | The helper initializes `DiarizerModels` / `DiarizerManager` and stores enrolled speaker embeddings. A model change must preserve or explicitly migrate those embeddings. |
| Local reminder TTS | VOICEVOX at `http://127.0.0.1:50021`; `POST /audio_query` then `POST /synthesis`; speaker/style ID 4 | The ID is a voice style, not an engine version. The installed engine and voice assets are provisioned outside this repo and were not inspected. |
| LINE reply TTS | The plugin calls the host's `line.reply-tts` contract | The host owns synthesis/model selection. The plugin carries admission/delivery provenance, not a cloud speech-model ID. |

Native speech uses Apple's
[SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber).
Whisper model filenames are application defaults, not a verified checksum or
proof of the contents of an existing local model file.

For FluidAudio, the [pinned model names](https://github.com/FluidInference/FluidAudio/blob/v0.15.2/Sources/FluidAudio/ModelNames.swift)
and [pinned loader](https://github.com/FluidInference/FluidAudio/blob/v0.15.2/Sources/FluidAudio/Diarizer/Core/DiarizerModels.swift)
were inspected. The current [v0.18.2 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.2)
adds functionality including CAM++ v2 speaker embeddings and changes offline
diarization defaults. Those changes do not establish that the existing helper
and enrolled voiceprints are interchangeable. No confirmed retirement or
mandatory migration for the pinned API was established; no blind update was
made. Its `from: "0.15.2"` manifest range and resolved pin are distinct.

VOICEVOX's [official README](https://github.com/VOICEVOX/voicevox_engine)
still documents the two synthesis endpoints used here. The app adjusts speed,
pitch, intonation, volume, and pause in the returned query, then normalizes WAV
output. There is no repository-pinned engine/model release to compare with a
production installation. No engine startup, synthesis, or personal audio was
used for this review.

## Confirmed finding: Whisper model-loader bounds checks

The [upstream fix](https://github.com/ggml-org/whisper.cpp/commit/60c0be6ac8fa71b1a2ae2dd938a31a34a508e774)
validates tensor-type bounds in model and VAD loading before the type is used.
The [v1.9.5 release](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5),
published 2026-10-06, includes the fix.
The public [CVE-2026-110810 advisory](https://github.com/advisories/GHSA-v488-xqq5-cf9f)
describes an out-of-bounds read involving a malformed model. This review did not
establish remote code execution in ClawGate or exploitation of its local models.

The provisioning default is advanced one patch release, with the existing
`WHISPER_CPP_TAG` override preserved. The v1.9.4 and v1.9.5
`examples/server/server.cpp` files were fetched from their exact upstream tags
and compared: their contents are identical, including the three
`whisper_lang_str_full(` call sites patched by this script. Therefore the
existing null-language compatibility patch remains applicable at the source
level. The rest of the upstream release still needs the build/runtime validation
listed below.

This change affects future server provisioning. It does not modify an already
installed server or the separately installed `whisper-cli` fallback. The latter's
actual version cannot be inferred from this repository and needs its own
installation inventory before any upgrade claim.

## Validation and remaining checks

- **Passed — source review:** exact upstream release/fix inspection; tagged
  server-source equality check; review of model IDs, selected efforts, API
  ownership, lockfiles, fallback/acknowledgement boundaries, and official
  provider catalog/deprecation documentation.
- **Not run — local commands:** the executor became unavailable before the edit
  could be applied locally. No shell syntax check, ShellCheck, or
  `git diff --check` result is claimed for this change. GitHub content entries
  were prepared from the immutable baseline instead.
- **Pending — CI:** the new pull request's checks must be evaluated separately.
  Results from the earlier maintenance PR do not validate this version bump.
- **Not run — runtime:** macOS/Metal build of v1.9.5, the patched no-speech/VAD
  response, server startup, local-model inference, Apple asset availability,
  FluidAudio re-enrollment compatibility, VOICEVOX synthesis, and live host or
  provider access were not exercised.
- **Tests added / removed / consolidated:** 0 / 0 / 0 in this focused change.
  A test that only asserts the version string would not validate the upstream
  native fix. Existing app tests are unchanged; independent suite rationalization
  is handled in the other RepoFix review stream.

Before using the rebuilt server in an installed app, build on macOS and verify
the retained null-language/no-speech behavior using nonpersonal fixtures.
Keep the reviewed model and VAD assets, isolate the server's dylibs as before,
and inventory the separate CLI installation. An intentional rollback can change
the provisioning tag, but v1.9.4 would restore the known bounds-check gap.
