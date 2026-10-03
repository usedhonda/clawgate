import XCTest
@testable import ClawGate

final class MeetingMinutesExecutionFinalizerTests: XCTestCase {
    private func fixture() throws -> (MeetingRecord, MeetingMinutesJob, MeetingStore) {
        let record = MeetingRecord(id: "mtg-finalizer", source: "manual", startedAt: 0,
                                   endedAt: 20, timeZone: "UTC", title: "Minutes",
                                   conferenceCode: nil, participants: [], minutesState: "pending",
                                   minutesError: nil)
        let segments = (0..<8).map {
            TranscriptSegment(startSeconds: Double($0), endSeconds: Double($0 + 1),
                              text: String(repeating: "speech \($0) ", count: 8))
        }
        let envelope = MeetingMinutesEnvelope.build(record: record, segments: segments)
        let envelopes = MeetingMinutes.chunked(envelope, maxCharacters: 220)
        XCTAssertGreaterThanOrEqual(envelopes.count, 2)
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope),
                                    envelopes: envelopes, completed: [])
        let store = MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-finalizer-\(UUID().uuidString)"))
        return (record, job, store)
    }

    private func answer(_ title: String) -> MeetingMinutes {
        MeetingMinutes(title: title, summary: title, topics: [], decisions: [],
                       actionItems: [], openQuestions: [], evidence: [],
                       attendance: nil, language: nil)
    }

    private func ack(_ d: MeetingMinutesExecutionState.Dispatch) throws -> MinutesExecutionAck {
        let fields: [String: Any] = ["resolvedModel": MinutesExecutionSendParams.model,
            "resolvedThinking": "high", "degraded": false, "fallbackReason": NSNull(),
            "isolationApplied": true, "nonprojectionApplied": true]
        var binding = fields
        binding["retentionApplied"] = true; binding["version"] = 1
        binding["requestFingerprintScheme"] = MinutesRequestFingerprint.scheme
        binding["requestFingerprint"] = try d.request.requestFingerprint()
        var object = fields
        object["status"] = "started"; object["sessionKey"] = d.sessionKey
        object["runId"] = d.idempotencyKey; object["executionBinding"] = binding
        object["resultRetentionExpiresAt"] = NSNull()
        let payload = try JSONDecoder().decode(IncomingPayload.self, from: JSONSerialization.data(withJSONObject: object))
        return try MinutesExecutionAck.validate(payload, expected: d.request)
    }

    func testOrderedAnswersKeepSilentPartsInTheCompletedJob() throws {
        let (record, job, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try job.save(store: store, id: record.id)
        var ledger = try MeetingMinutesExecutionState(job: job)
        for start in stride(from: 0, to: job.envelopes.count, by: 2) {
            var batch: [MeetingMinutesExecutionState.Dispatch] = []
            for index in start..<min(start + 2, job.envelopes.count) {
                batch.append(try ledger.reserve(index: index, sessionKey: "agent:example:main", message: "fixture \(index)", store: store, id: record.id))
            }
            for d in batch.reversed() {
                try ledger.acknowledge(d, ack: ack(d), store: store, id: record.id)
                let outcome: MeetingMinutesExecutionState.Outcome = d.index == 1 ? .insufficientEvidence : .answer(answer("part \(d.index)"))
                try ledger.complete(d, runId: d.idempotencyKey, outcome: outcome, store: store, id: record.id)
            }
        }
        let projection = MeetingMinutesExecutionProgress(ledger: ledger)
        XCTAssertEqual(projection.completedIndices, Set(job.envelopes.indices))
        XCTAssertTrue(projection.activeIndices.isEmpty)
        let result = try MeetingMinutesExecutionFinalizer.finalize(
            ledger: ledger, frozenJob: job, record: record, store: store, id: record.id)
        XCTAssertEqual(result.completedJob.completed.count, job.envelopes.count)
        for index in job.envelopes.indices {
            XCTAssertEqual(result.completedJob.completed[index]?.title, index == 1 ? nil : "part \(index)")
        }
        XCTAssertNotNil(store.loadAcceptedMinutes(id: record.id))
        XCTAssertTrue(try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id)).completed.isEmpty)
        let repeated = try MeetingMinutesExecutionFinalizer.finalize(ledger: ledger, frozenJob: job, record: record, store: store, id: record.id)
        XCTAssertFalse(repeated.wroteAcceptedBundle)
    }

    func testIncompleteLedgerDoesNotReplaceAnAcceptedBundle() throws {
        let (record, original, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var acceptedJob = original
        acceptedJob.completed = Array(repeating: answer("old"), count: acceptedJob.envelopes.count)
        try store.saveValidatedMinutes(try XCTUnwrap(MeetingMinutes.combining(acceptedJob.completed.compactMap { $0 })),
                                       for: record, job: acceptedJob)
        let before = try Data(contentsOf: store.directory(for: record.id)
            .appendingPathComponent("minutes-accepted.json"))
        try original.save(store: store, id: record.id)
        let ledger = try MeetingMinutesExecutionState(job: original)
        XCTAssertThrowsError(try MeetingMinutesExecutionFinalizer.finalize(
            ledger: ledger, frozenJob: original, record: record, store: store, id: record.id))
        XCTAssertEqual(try Data(contentsOf: store.directory(for: record.id)
            .appendingPathComponent("minutes-accepted.json")), before)
    }

    func testChangedCurrentJobRefusesPublication() throws {
        let (record, original, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var frozen = original
        frozen.completed = Array(repeating: answer("frozen"), count: frozen.envelopes.count)
        try frozen.save(store: store, id: record.id)
        var ledger = try MeetingMinutesExecutionState(job: frozen)
        try ledger.save(store: store, id: record.id)
        var changed = frozen
        changed.completed[0] = answer("newer")
        try changed.save(store: store, id: record.id)
        XCTAssertThrowsError(try MeetingMinutesExecutionFinalizer.finalize(
            ledger: ledger, frozenJob: frozen, record: record, store: store, id: record.id))
        XCTAssertNil(store.loadAcceptedMinutes(id: record.id))
    }
    func testJobWriterCannotRaceLockedPublicationCheck() throws {
        let (record, job, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try job.save(store: store, id: record.id)
        var changed = job; changed.userRequestedAt = Date()
        try MeetingMinutesJob.withCurrentRevisionLock(store: store, id: record.id, expected: job) {
            XCTAssertThrowsError(try changed.save(store: store, id: record.id))
        }
        try changed.save(store: store, id: record.id)
        XCTAssertNoThrow(try MeetingMinutesJob.withCurrentRevisionLock(store: store, id: record.id, expected: job) {})
    }

}
