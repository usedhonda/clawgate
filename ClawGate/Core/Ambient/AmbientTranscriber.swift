import Foundation

/// One transcript segment with timing relative to the start of the audio file.
struct TranscriptSegment: Codable, Equatable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    /// Absolute wall-clock time of this utterance (unix seconds), stamped at
    /// chunk-capture time. Optional for backward compatibility with raw.jsonl
    /// lines written before timestamps existed.
    var capturedAt: Double? = nil
}

/// A segment dropped during filtering, with the reason (for skipped.jsonl audit).
struct SkippedSegment: Codable, Equatable {
    let reason: String
    let segment: TranscriptSegment
}

/// Result of transcribing one chunk: kept segments plus what was filtered out.
struct TranscriptionResult {
    let kept: [TranscriptSegment]
    let skipped: [SkippedSegment]
}

/// Named STT quality preset — noisy-room tuned defaults from
/// docs/ambient-stt-quality.md. `maxContext: 0` is the main loop-repetition
/// killer; thresholds + duplicate filtering trim hallucinated filler.
struct AmbientPreset: Codable {
    var name = "large-metal-noisy-room-v2"
    var engine = "whisper.cpp"
    var backend = "Metal"
    var model = "large-v3-turbo"
    var maxContext = 0
    var beamSize = 5
    var noSpeechThreshold = 0.30
    var entropyThreshold = 2.80
    var duplicateFilter = true
    /// Silero VAD gates whisper to actual speech regions. This is the root
    /// hallucination fix: energy alone can't tell "loud non-speech" from
    /// speech, and whisper invents text for the former (verified 2026-06-10:
    /// three real garbage chunks → 0 segments with VAD, while rendered real
    /// speech transcribed verbatim).
    var vad = true
    var vadModel = "silero-v5.1.2"
    /// Suppress non-speech tokens ("*coughs*", "(music)") at decode time.
    var suppressNonSpeech = true

    static let defaultPrompt = "This is a live room conversation. Expect startup, product, revenue, fundraising, operations, engineering, and personal-assistant context. Preserve names and technical terms when heard. Do not invent content for unclear audio."
}

/// Shells out to a whisper.cpp `whisper-cli` binary to transcribe a WAV chunk.
///
/// The binary and model are provisioned out-of-repo under Application Support
/// (see AmbientStorage). Invocation:
///   whisper-cli -m <model> -f <wav> -oj -of <prefix> -l <lang> -t <threads>
/// which writes `<prefix>.json` in the whisper.cpp standard shape:
///   { "transcription": [ { "offsets": {"from": ms, "to": ms}, "text": "..." } ] }
final class AmbientTranscriber {
    enum TranscribeError: Error, CustomStringConvertible {
        case binaryMissing(String)
        case modelMissing(String)
        case launchFailed(String)
        case nonZeroExit(Int32, String)
        case outputMissing(String)
        case decodeFailed(String)

        var description: String {
            switch self {
            case .binaryMissing(let p): return "whisper-cli not found or not executable at \(p)"
            case .modelMissing(let p): return "whisper model not found at \(p)"
            case .launchFailed(let m): return "failed to launch whisper-cli: \(m)"
            case .nonZeroExit(let c, let m): return "whisper-cli exited \(c): \(m)"
            case .outputMissing(let p): return "whisper-cli produced no json at \(p)"
            case .decodeFailed(let m): return "failed to decode whisper json: \(m)"
            }
        }
    }

    let binary: URL
    let model: URL
    let preset: AmbientPreset
    let prompt: String

    init(binary: URL = AmbientStorage.defaultWhisperBinary,
         model: URL = AmbientStorage.defaultWhisperModel,
         preset: AmbientPreset = AmbientPreset(),
         prompt: String = AmbientPreset.defaultPrompt) {
        self.binary = binary
        self.model = model
        self.preset = preset
        self.prompt = prompt
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: binary.path)
            && FileManager.default.fileExists(atPath: model.path)
    }

    /// Transcribe a WAV chunk. `language` nil → auto-detect.
    func transcribe(chunk: URL, language: String? = nil) throws -> TranscriptionResult {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TranscribeError.binaryMissing(binary.path)
        }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscribeError.modelMissing(model.path)
        }

        let prefix = chunk.deletingPathExtension()
        let jsonURL = prefix.appendingPathExtension("json")
        try? FileManager.default.removeItem(at: jsonURL)

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "-m", model.path,
            "-f", chunk.path,
            "-oj",
            "-of", prefix.path,
            "-l", language ?? "auto",
            "-t", "\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))",
            "-mc", "\(preset.maxContext)",
            "-bs", "\(preset.beamSize)",
            "-nth", "\(preset.noSpeechThreshold)",
            "-et", "\(preset.entropyThreshold)",
            "--prompt", prompt,
            "-np",
        ]
        if preset.suppressNonSpeech {
            proc.arguments?.append("-sns")
        }
        // VAD only when the silero model is provisioned — degrade gracefully
        // to the old (hallucination-prone) behavior rather than failing.
        let vadModel = AmbientStorage.defaultVADModel
        if preset.vad, FileManager.default.fileExists(atPath: vadModel.path) {
            proc.arguments?.append(contentsOf: ["--vad", "-vm", vadModel.path])
        }
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
        } catch {
            throw TranscribeError.launchFailed("\(error)")
        }
        proc.waitUntilExit()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw TranscribeError.nonZeroExit(proc.terminationStatus, String(errText.suffix(500)))
        }

        guard let data = try? Data(contentsOf: jsonURL) else {
            throw TranscribeError.outputMissing(jsonURL.path)
        }
        let segments = try Self.parse(data)
        return Self.classify(segments)
    }

    // MARK: - whisper.cpp JSON shape

    private struct WhisperJSON: Decodable {
        struct Item: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Item]
    }

    static func parse(_ data: Data) throws -> [TranscriptSegment] {
        do {
            let decoded = try JSONDecoder().decode(WhisperJSON.self, from: data)
            return decoded.transcription.map {
                TranscriptSegment(
                    startSeconds: Double($0.offsets.from) / 1000.0,
                    endSeconds: Double($0.offsets.to) / 1000.0,
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.text.isEmpty }
        } catch {
            throw TranscribeError.decodeFailed("\(error)")
        }
    }

    /// Whole-segment texts that are canonical whisper hallucinations (media
    /// sign-offs and filler whisper invents on unclear audio). Matched only
    /// when they constitute the entire segment — never inside real sentences.
    static let hallucinationBoilerplate: Set<String> = [
        "thank you.", "thank you", "thanks for watching", "thanks for watching.",
        "you", "bye.", "see you next time.", "we'll be right back.",
        "ご視聴ありがとうございました", "ご視聴ありがとうございました。",
        "チャンネル登録お願いします", "最後までご視聴ありがとうございました",
    ]

    /// Split segments into kept vs skipped (with reasons). Defense-in-depth
    /// behind the VAD: drops zero-duration boundary fillers, sound-effect
    /// markers, canonical hallucination boilerplate, consecutive duplicates,
    /// and repetition loops.
    static func classify(_ segments: [TranscriptSegment]) -> TranscriptionResult {
        var kept: [TranscriptSegment] = []
        var skipped: [SkippedSegment] = []
        for seg in segments {
            // Zero/near-zero duration segments at chunk boundaries are EOF
            // hallucinations ("- Thank you." at [30.0-30.0s]).
            if seg.endSeconds - seg.startSeconds < 0.5 {
                skipped.append(SkippedSegment(reason: "zero_duration", segment: seg))
                continue
            }
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // "*coughs*", "(music)", "[applause]" — non-speech markers.
            if isNonSpeechMarker(trimmed) {
                skipped.append(SkippedSegment(reason: "non_speech_marker", segment: seg))
                continue
            }
            let normalized = trimmed.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "-– "))
            if hallucinationBoilerplate.contains(normalized) {
                skipped.append(SkippedSegment(reason: "hallucination_boilerplate", segment: seg))
                continue
            }
            if isInternalRepetition(seg.text) {
                skipped.append(SkippedSegment(reason: "internal_repetition", segment: seg))
                continue
            }
            if let last = kept.last, last.text == seg.text {
                skipped.append(SkippedSegment(reason: "immediate_duplicate", segment: seg))
                continue
            }
            kept.append(seg)
        }
        return TranscriptionResult(kept: kept, skipped: skipped)
    }

    /// Sound-effect annotation covering the whole segment: *coughs*, (music).
    static func isNonSpeechMarker(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        switch (first, last) {
        case ("*", "*"), ("(", ")"), ("[", "]"): return true
        default: return false
        }
    }

    /// A segment that is essentially a token/phrase repeated in a loop.
    static func isInternalRepetition(_ text: String) -> Bool {
        // Word-level: few unique words spread over many ("yeah yeah yeah").
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.count >= 4, Set(words).count <= max(1, words.count / 4) { return true }
        // Phrase-level: any 3-word phrase occurring 3+ times ("I was in the
        // first place. I was in the first place. I was…").
        if words.count >= 9 {
            var counts: [String: Int] = [:]
            for i in 0...(words.count - 3) {
                let gram = words[i...(i + 2)].joined(separator: " ")
                counts[gram, default: 0] += 1
                if counts[gram] == 3 { return true }
            }
        }
        // Character-level for unspaced JP: the text is one short unit repeated
        // ("餃子餃子餃子").
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if chars.count >= 6 {
            for unit in 2...max(2, chars.count / 3) {
                guard chars.count % unit == 0 else { continue }
                let first = Array(chars[0..<unit])
                var repeats = true
                for start in stride(from: unit, to: chars.count, by: unit)
                where Array(chars[start..<(start + unit)]) != first {
                    repeats = false; break
                }
                if repeats { return true }
            }
        }
        return false
    }
}
