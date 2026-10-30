import XCTest
@testable import ClawGate

final class MeetingMinutesKnowledgeTests: XCTestCase {
    private func record(_ id: String = "meeting") -> MeetingRecord {
        MeetingRecord(id: id, source: "calendar", startedAt: 100, endedAt: 200,
            timeZone: "UTC", title: "Meeting", conferenceCode: nil, participants: [],
            minutesState: "ready", minutesError: nil)
    }

    private func accepted(_ record: MeetingRecord, summary: String = "Grounded summary",
                          historical: Bool = false) throws -> Data {
        let minutes = MeetingMinutes(title: "Meeting", summary: summary, topics: [], decisions: [],
            actionItems: [], openQuestions: [],
            evidence: [MeetingEvidence(claim: summary, segmentIds: ["speech-1"])],
            attendance: nil, language: "ja")
        let segment = MeetingMinutesSegment(sourceSegment: MeetingTranscriptSourceSegment(
            id: "speech-1", source: "external", text: "Unshared original speech",
            sourceURL: "https://example.invalid/source", sourceLocator: "line:1"))
        return try JSONEncoder().encode(MeetingAcceptedMinutes(minutes: minutes, fingerprint: "same-input",
            segments: [segment], unresolvedNotes: ["Incomplete coverage"], createdAt: Date(timeIntervalSince1970: 300),
            knowledgeContext: historical ? nil : .init(record: record), coverageHints: ["Selected interval only"]))
    }

    func testLegacySelectionIsExplicitAndGenerationContextIsFrozen() throws {
        let original = record()
        let legacy = try accepted(original, historical: true)
        XCTAssertThrowsError(try MeetingMinutesKnowledgeSnapshot(acceptedData: legacy, record: original)) {
            XCTAssertEqual($0 as? MeetingMinutesKnowledgeSnapshot.SnapshotError, .historicalSelectionRequired)
        }
        XCTAssertEqual(try MeetingMinutesKnowledgeSnapshot(acceptedData: legacy, record: original,
            explicitlySelected: true).contextBasis, "historical_selection_current_metadata")

        let current = try accepted(original)
        var edited = original; edited.startedAt = 500
        let snapshot = try MeetingMinutesKnowledgeSnapshot(acceptedData: current, record: edited)
        XCTAssertEqual(snapshot.context.startedAt, 100)
        XCTAssertThrowsError(try MeetingMinutesKnowledgeSnapshot(acceptedData: current, record: record("other")))
    }

    func testOutputRevisionIsNotInputFingerprintAndRawSpeechDoesNotLeaveProjection() throws {
        let r = record(), first = try accepted(r), second = try accepted(r, summary: "Revised grounded summary")
        let a = try MeetingMinutesKnowledgeSnapshot(acceptedData: first, record: r)
        let b = try MeetingMinutesKnowledgeSnapshot(acceptedData: second, record: r)
        XCTAssertEqual(a.inputFingerprint, b.inputFingerprint)
        XCTAssertNotEqual(a.outputRevision, b.outputRevision)
        XCTAssertEqual(a.outputRevision, try MeetingMinutesKnowledgeSnapshot(acceptedData: first, record: r).outputRevision)
        XCTAssertEqual(a.citations.map(\.id), ["speech-1"])
        XCTAssertEqual(a.citations.first?.sourceLocator, "line:1")
        XCTAssertEqual(a.unresolvedNotes, ["Incomplete coverage"])
        XCTAssertEqual(a.coverageHints, ["Selected interval only"])
        XCTAssertEqual(a.coverageBasis, "selected_input_only")
        let body = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertFalse(body.contains("Unshared original speech"))
    }

    func testRestartReconciliationRecoversNewDocumentButDoesNotEnrollHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let new = record("new"), old = record("old")
        for (r, legacy) in [(new, false), (old, true)] {
            let directory = store.directory(for: r.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try accepted(r, historical: legacy).write(to: directory.appendingPathComponent("minutes-accepted.json"))
        }
        let queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.reconcile(store: store, records: [new, old])
        try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
            .reconcile(store: store, records: [new, old])
        XCTAssertEqual(try queue.pending().map(\.context.meetingID), ["new"])
        let item = queue.directory.appendingPathComponent("state.json")
        try Data("corrupted binding".utf8).write(to: item)
        let originalBytes = try Data(contentsOf: store.directory(for: new.id).appendingPathComponent("minutes-accepted.json"))
        XCTAssertThrowsError(try queue.enqueue(acceptedData: originalBytes, record: new)) {
            XCTAssertEqual($0 as? AudioHubOutbox.Error, .conflict)
        }
    }

    func testCapacityPreservesPendingAndAcceptedRevisionForLaterRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root), r = record()
        let directory = store.directory(for: r.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("minutes-accepted.json")
        let first = try accepted(r)
        try first.write(to: source, options: .atomic)
        let small = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 4096)
        let queued = try small.enqueue(acceptedData: first, record: r)
        let revised = try accepted(r, summary: String(repeating: "Revised discussion ", count: 500))
        try revised.write(to: source, options: .atomic)
        XCTAssertThrowsError(try small.enqueue(acceptedData: revised, record: r)) {
            XCTAssertEqual($0 as? AudioHubOutbox.Error, .capacityExceeded)
        }
        XCTAssertEqual(try Data(contentsOf: source), revised)
        XCTAssertEqual(try small.pending().map(\.outputRevision), [queued.outputRevision])
        let restored = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try restored.reconcile(store: store, records: [r])
        XCTAssertEqual(try restored.pending().count, 2)
        XCTAssertEqual(try Data(contentsOf: source), revised)
    }
}
