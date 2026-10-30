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
    private func receipt(_ item: MeetingMinutesPublication,
                         status: MeetingMinutesPublicationReceipt.Status,
                         current: Bool = true, hash: String? = nil) -> MeetingMinutesPublicationReceipt {
        .init(schemaVersion: 1, sourceUUID: item.sourceUUID, meetingID: item.meetingID,
              publicationOrdinal: item.publicationOrdinal, outputRevision: item.outputRevision,
              payloadSHA256: hash ?? item.payloadSHA256, status: status, isCurrent: current)
    }

    func testPublicationStoredRestartAndSearchabilityDoNotReenqueueOrArchiveBody() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = record(), bytes = try accepted(r)
        var queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: bytes, record: r)
        let item = try XCTUnwrap(queue.publications().first)
        XCTAssertEqual(item.publicationOrdinal, 1)
        XCTAssertNil(item.previousRevision)
        XCTAssertEqual(item.selectionBasis, .futureAccepted)
        XCTAssertEqual(MeetingMinutesPublication.digest(try XCTUnwrap(Data(base64Encoded: item.payloadBase64))), item.payloadSHA256)
        XCTAssertThrowsError(try queue.receive(receipt(item, status: .stored, hash: "wrong"), expected: item))
        XCTAssertEqual(try queue.publications().count, 1)
        try queue.receive(receipt(item, status: .pendingGap), expected: item)
        XCTAssertEqual(try queue.publications().count, 1)
        try queue.receive(receipt(item, status: .stored), expected: item)
        queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: bytes, record: r)
        XCTAssertTrue(try queue.publications().isEmpty)
        XCTAssertEqual(try queue.awaitingSearchability(), [item])
        try queue.receive(receipt(item, status: .searchable), expected: item)
        try queue.receive(receipt(item, status: .stored), expected: item) // delayed reply cannot regress
        XCTAssertTrue(try queue.awaitingSearchability().isEmpty)
        queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: bytes, record: r)
        XCTAssertTrue(try queue.publications().isEmpty)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            queue.directory.appendingPathComponent("state.json"))) as? [String: Any])
        let entries = try XCTUnwrap(state["entries"] as? [[String: Any]])
        XCTAssertNil(entries.first?["payload"])
    }

    func testPublicationRevisionOrderingSelectionAndExactEnvelopeReceipt() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = record(), first = try accepted(r), second = try accepted(r, summary: "Revised")
        let queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: first, record: r)
        try queue.enqueue(acceptedData: second, record: r, explicitlySelected: true)
        try queue.enqueue(acceptedData: first, record: r) // old revision does not allocate a new ordinal
        let items = try queue.publications()
        XCTAssertEqual(items.map(\.publicationOrdinal), [1, 2])
        XCTAssertEqual(items[1].previousRevision, items[0].outputRevision)
        XCTAssertEqual(items[1].selectionBasis, .explicitHistory)
        let changed = MeetingMinutesPublication(schemaVersion: 1, operation: .delete,
            sourceUUID: items[1].sourceUUID, meetingID: r.id, outputRevision: items[1].outputRevision,
            publicationOrdinal: 2, previousRevision: items[0].outputRevision,
            selectionBasis: .explicitHistory, payloadSHA256: items[1].payloadSHA256, payloadBase64: items[1].payloadBase64)
        XCTAssertThrowsError(try queue.receive(receipt(items[1], status: .stored), expected: changed))
        try queue.receive(receipt(items[1], status: .stored), expected: items[1])
        try queue.receive(receipt(items[0], status: .stored, current: false), expected: items[0])
        XCTAssertEqual(try queue.awaitingSearchability(), [items[1]])
        XCTAssertTrue(try queue.publications().isEmpty)
    }

    func testPublicationExplicitDeletionCannotBeResurrectedByOldAcceptedFile() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = record(), bytes = try accepted(r)
        var queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: bytes, record: r)
        let upsert = try XCTUnwrap(queue.publications().first)
        try queue.receive(receipt(upsert, status: .searchable), expected: upsert)
        try queue.enqueueDeletion(meetingID: r.id, expectedRevision: upsert.outputRevision)
        let deletion = try XCTUnwrap(queue.publications().first)
        XCTAssertEqual(deletion.operation, .delete)
        XCTAssertEqual(deletion.publicationOrdinal, 2)
        XCTAssertEqual(deletion.payloadSHA256, MeetingMinutesPublication.digest(Data()))
        XCTAssertEqual(deletion.payloadBase64, "")
        XCTAssertThrowsError(try queue.receive(receipt(deletion, status: .stored), expected: deletion))
        try queue.receive(receipt(deletion, status: .deleted), expected: deletion)
        queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        XCTAssertThrowsError(try queue.enqueue(acceptedData: bytes, record: r))
        try queue.enqueueDeletion(meetingID: r.id, expectedRevision: upsert.outputRevision)
        XCTAssertTrue(try queue.publications().isEmpty)
    }

}
