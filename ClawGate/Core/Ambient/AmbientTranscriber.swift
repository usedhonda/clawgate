import Foundation

/// One transcript segment with timing relative to the start of the audio file.
struct TranscriptSegment: Codable, Equatable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

/// Named STT quality preset — noisy-room tuned defaults from
/// docs/ambient-stt-quality.md. `maxContext: 0` is the main loop-repetition
/// killer; thresholds + duplicate filtering trim hallucinated filler.
struct AmbientPreset: Codable {
    var name = "large-metal-noisy-room-v1"
    var engine = "whisper.cpp"
    var backend = "Metal"
    var model = "large-v3-turbo"
    var maxContext = 0
    var beamSize = 5
    var noSpeechThreshold = 0.30
    var entropyThreshold = 2.80
    var duplicateFilter = true

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
    func transcribe(chunk: URL, language: String? = nil) throws -> [TranscriptSegment] {
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
        return Self.filterRepetitions(segments)
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

    /// Drop obvious repeated loop text (consecutive identical segments) — a
    /// common whisper hallucination on silence.
    static func filterRepetitions(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for seg in segments {
            if let last = out.last, last.text == seg.text { continue }
            out.append(seg)
        }
        return out
    }
}
