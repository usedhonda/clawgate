import AVFoundation
import XCTest
@testable import ClawGate

final class MeetingBackfillIntegrationTests: XCTestCase {
    func testBackfillCarriesOnlyUnambiguousLiveSpeakerLabels() {
        var speech = TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "backfill")
        speech.capturedAt = 100
        speech.stream = "system"
        var live = TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "live")
        live.capturedAt = 100
        live.stream = "system"
        live.speakerName = "Guest"
        let named = MeetingBackfill.carryLiveSpeakerLabels([speech], from: [live], meetingSource: "meet")
        XCTAssertEqual(named.first?.speakerName, "Guest")
        var conflicting = live
        conflicting.speakerName = "Someone else"
        XCTAssertNil(MeetingBackfill.carryLiveSpeakerLabels([speech], from: [live, conflicting],
                     meetingSource: "meet").first?.speakerName)
        live.stream = "mic"
        XCTAssertNil(MeetingBackfill.carryLiveSpeakerLabels([speech], from: [live],
                     meetingSource: "meet").first?.speakerName)
        speech.stream = "mic"
        live.speaker = "other"
        XCTAssertEqual(MeetingBackfill.carryLiveSpeakerLabels([speech], from: [live],
                       meetingSource: "manual").first?.speaker, "other")
    }

    func testSyntheticSpeechBecomesMeetingTranscript() throws {
        guard ProcessInfo.processInfo.environment["CLAWGATE_MEETING_E2E"] == "1" else {
            throw XCTSkip("opt-in test requires local Whisper model")
        }
        guard AmbientTranscriber().isAvailable else {
            throw XCTSkip("Whisper CLI and model are not installed")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let spoken = root.appendingPathComponent("spoken.aiff")
        let wav = root.appendingPathComponent("spoken.wav")
        try run("/usr/bin/say", ["-o", spoken.path,
                                  "The project meeting begins now. We will review the agenda and assign tasks."])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                                       spoken.path, wav.path])

        let file = try AVAudioFile(forReading: wav)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertGreaterThan(duration, 1)
        let archive = MeetingAudioArchive(root: root.appendingPathComponent("archive"))
        let store = MeetingStore(root: root.appendingPathComponent("meetings"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try archive.archive(.init(url: wav, sequence: 1, rms: 0.1, startedAt: start,
                                  actualPrimedFrames: 0, sampleRate: 16_000,
                                  provenOverlap: false, source: .mic))
        let record = try MeetingBackfill(archive: archive, store: store)
            .createMeeting(start: start, end: start.addingTimeInterval(duration), title: "Synthetic meeting")
        XCTAssertEqual(store.load(id: record.id)?.title, "Synthetic meeting")
        let transcript = try XCTUnwrap(store.loadBackfill(id: record.id))
        XCTAssertFalse(transcript.isEmpty)
        XCTAssertTrue(transcript.allSatisfy { $0.stream == "mic" && $0.capturedAt != nil })
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
