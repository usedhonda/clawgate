import XCTest
@testable import ClawGate

/// End-to-end language routing through the real transcriber: Japanese stays on
/// Apple's engine, anything else is re-run through whisper's auto-detect.
///
/// Opt-in, like `AmbientLiveIngestTests`, because it needs the locally
/// provisioned whisper model and real audio. Run with:
///
///   STT_JA_WAV=<16k mono ja wav> STT_EN_WAV=<16k mono en wav> \
///     swift test --filter AmbientLanguageRoutingTests
final class AmbientLanguageRoutingTests: XCTestCase {
    private func wav(_ key: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[key] else {
            throw XCTSkip("\(key) not set")
        }
        return URL(fileURLWithPath: path)
    }

    func testJapaneseStaysOnAppleAndKeepsItsSpeakerLabels() throws {
        let transcriber = AmbientTranscriber()
        let turns = [SpeakerTurn(start: 0, end: 600, speaker: "self", score: 1)]
        let result = try transcriber.transcribe(chunk: try wav("STT_JA_WAV"), turns: turns)
        XCTAssertEqual(transcriber.nonPrimaryChunks, 0, "Japanese must not be re-run through whisper")
        XCTAssertTrue(result.speakerLabeled, "Apple's grouping applies the diarizer's turns")
        XCTAssertFalse(result.kept.isEmpty)
        XCTAssertEqual(result.kept.first?.speaker, "self")
        // Not latin — this is the property the router keys on.
        XCTAssertFalse(AppleSpeechEngine.looksNonPrimary(result.kept.map(\.text).joined()))
    }

    func testEnglishIsRoutedToWhisperAndComesBackReadable() throws {
        let transcriber = AmbientTranscriber()
        let turns = [SpeakerTurn(start: 0, end: 600, speaker: "other", score: 1)]
        let result = try transcriber.transcribe(chunk: try wav("STT_EN_WAV"), turns: turns)
        XCTAssertEqual(transcriber.nonPrimaryChunks, 1, "English must be handed to whisper")
        XCTAssertFalse(result.speakerLabeled, "whisper's segments still need the diarizer applied")
        let text = result.kept.map(\.text).joined(separator: " ").lowercased()
        XCTAssertFalse(text.isEmpty)
        // Real words, not the Japanese model's mangled latin.
        XCTAssertTrue(text.contains("quarterly") || text.contains("migration") || text.contains("rollout"),
                      "expected recognizable English, got: \(text)")
    }
}
