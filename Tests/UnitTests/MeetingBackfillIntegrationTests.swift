import AVFoundation
import XCTest
@testable import ClawGate

final class MeetingBackfillIntegrationTests: XCTestCase {
    /// Opt-in recovery check against the owner's retained archive and calendar.
    /// Selection is exact, and no production record is changed if the calendar
    /// result is absent or ambiguous. No private event identifiers are fixtures.
    func testRealCalendarAnchoredSplitMeetingRecoveryWhenOptedIn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let targetID = environment["CLAWGATE_MEETING_REAL_TARGET"],
              let scheduledStart = environment["CLAWGATE_MEETING_REAL_START"],
              let scheduledEnd = environment["CLAWGATE_MEETING_REAL_END"] else {
            throw XCTSkip("opt-in real archive recovery")
        }
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: scheduledStart))
        let end = try XCTUnwrap(formatter.date(from: scheduledEnd))
        let store = MeetingStore()
        let original = try XCTUnwrap(store.load(id: targetID))
        let oldMinutes = try XCTUnwrap(store.loadMinutes(id: targetID))
        let matches = try MeetingCandidateSource.candidates().filter {
            $0.matchedMeetingID == targetID &&
                abs($0.start.timeIntervalSince(start)) < 1 &&
                abs($0.end.timeIntervalSince(end)) < 1
        }
        let candidate = try XCTUnwrap(matches.count == 1 ? matches.first : nil,
                                      "calendar match must be unique")
        let proposedStart = try XCTUnwrap(candidate.proposedStart)
        let proposedEnd = try XCTUnwrap(candidate.proposedEnd)
        if environment["CLAWGATE_MEETING_REAL_EXPECT_GAP"] == "1" {
            XCTAssertTrue(candidate.boundaryEvidence.contains("録音に欠落あり"))
        }
        let recovered = try MeetingBackfill().createMeeting(
            start: proposedStart, end: proposedEnd, title: candidate.title, candidate: candidate)
        XCTAssertEqual(recovered.id, targetID)
        XCTAssertEqual(recovered.minutesState, "pending")
        XCTAssertEqual(store.loadMinutes(id: targetID), oldMinutes)
        let transcript = try XCTUnwrap(store.loadBackfill(id: targetID))
        XCTAssertTrue(transcript.contains { ($0.capturedAt ?? .infinity) < original.startedAt })
        XCTAssertGreaterThan(transcript.count, 100)
        for id in candidate.matchingMeetingIDs where id != targetID {
            XCTAssertEqual(store.load(id: id)?.mergedIntoMeetingID, targetID)
        }
    }

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
