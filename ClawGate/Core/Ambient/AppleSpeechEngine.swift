import AVFoundation
import Foundation
import Speech

/// Apple's on-device transcriber (SpeechAnalyzer + SpeechTranscriber, macOS 26)
/// as an ambient STT engine. It runs on the Neural Engine with a system-managed
/// model, so it needs no resident process and far less memory and heat than
/// whisper large-v3-turbo.
///
/// Segments carry start/end seconds within the chunk, taken from the
/// transcriber's audio time ranges, so the self/other diarizer aligns with them
/// exactly as it does with whisper's segments.
enum AppleSpeechEngine {
    static let localeIdentifier = "ja-JP"

    /// True when the running OS has the API and the Japanese model is installed.
    static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return installed
    }

    @available(macOS 26.0, *)
    private static let installed: Bool = {
        let done = DispatchSemaphore(value: 0)
        var found = false
        Task.detached {
            let locales = await SpeechTranscriber.installedLocales
            found = locales.contains { $0.identifier(.bcp47) == localeIdentifier }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return found
    }()

    /// Transcribe a WAV file synchronously (called on the transcription queue).
    static func transcribe(chunk: URL, turns: [SpeakerTurn]? = nil, timeout: TimeInterval = 120) throws -> [TranscriptSegment] {
        guard #available(macOS 26.0, *) else {
            throw AmbientTranscriber.TranscribeError.launchFailed("SpeechAnalyzer needs macOS 26")
        }
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<[TranscriptSegment], Error> = .success([])
        Task.detached {
            do {
                outcome = .success(group(try await run(chunk: chunk), turns: turns))
            } catch {
                outcome = .failure(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw AmbientTranscriber.TranscribeError.launchFailed("SpeechAnalyzer timed out")
        }
        return try outcome.get()
    }

    /// Whether this text reads as a language other than the transcriber's.
    ///
    /// Apple's SpeechTranscriber is locked to one locale, and the Japanese model
    /// fed English speech returns near-pure latin gibberish, so the script mix of
    /// its own output is the cheapest possible detector — Japanese chunks cost
    /// nothing extra. Measured over 984 real segments of at least `minScripted`
    /// letters: the English meeting's output ran 0.600–1.000 latin, real Japanese
    /// 0.000–0.381 (mean 0.007). The threshold sits below that gap on purpose.
    /// A false positive is cheap — whisper detects the language itself and
    /// transcribes Japanese just as well, so the only cost is a second pass —
    /// while a false negative leaves the chunk as gibberish. Short replies
    /// ("OK, thanks" inside a Japanese meeting) are below the length floor and
    /// never trip it.
    static func looksNonPrimary(_ text: String, threshold: Double = 0.4, minScripted: Int = 15) -> Bool {
        var latin = 0, scripted = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.decimalDigits.contains(scalar) { continue }
            scripted += 1
            if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) { latin += 1 }
        }
        guard scripted >= minScripted else { return false }
        return Double(latin) / Double(scripted) >= threshold
    }

    /// One timed piece of recognized text (Apple times each character).
    struct Piece: Equatable {
        let text: String
        let start: Double
        let end: Double
    }

    /// Apple returns long results that can span both speakers, so a result is
    /// never one segment. Pieces are grouped into segments that end at a
    /// sentence mark, at a pause, or where the diarizer's speaker changes; each
    /// segment carries that speaker. A piece outside every turn keeps the
    /// current speaker rather than splitting a sentence.
    static func group(_ pieces: [Piece], turns: [SpeakerTurn]?, pauseSeconds: Double = 0.8) -> [TranscriptSegment] {
        func speaker(at t: Double) -> String? {
            turns?.first { $0.start <= t && t <= $0.end }?.speaker
        }
        var segments: [TranscriptSegment] = []
        var text = "", start = 0.0, end = 0.0
        var current: String? = nil
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                var seg = TranscriptSegment(startSeconds: start, endSeconds: end, text: trimmed)
                seg.speaker = current
                segments.append(seg)
            }
            text = ""
        }
        for piece in pieces {
            let who = speaker(at: (piece.start + piece.end) / 2) ?? current
            let paused = !text.isEmpty && piece.start - end >= pauseSeconds
            if !text.isEmpty, paused || (who != nil && current != nil && who != current) { flush() }
            if text.isEmpty { start = piece.start }
            if who != nil { current = who }
            text += piece.text
            end = piece.end
            if let last = piece.text.last, "。？！?!".contains(last) { flush() }
        }
        flush()
        return segments
    }

    @available(macOS 26.0, *)
    private static func run(chunk: URL) async throws -> [Piece] {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: localeIdentifier),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: chunk)
        let collector = Task {
            var pieces: [Piece] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    pieces.append(Piece(text: text, start: range.start.seconds, end: range.end.seconds))
                }
            }
            return pieces
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}
