import XCTest
@testable import ClawGate

final class MeetingMinutesExecutionStateTests: XCTestCase {
    private func response(_ d: MeetingMinutesExecutionState.Dispatch, status: String = "started", terminal: [String: Any]? = nil) throws -> IncomingPayload {
        let binding: [String: Any] = ["version": 1, "requestFingerprintScheme": MinutesRequestFingerprint.scheme,
            "requestFingerprint": try d.request.requestFingerprint(), "resolvedModel": MinutesExecutionSendParams.model,
            "resolvedThinking": "high", "degraded": false, "fallbackReason": NSNull(),
            "isolationApplied": true, "nonprojectionApplied": true, "retentionApplied": true]
        var object: [String: Any] = ["status": status, "sessionKey": d.sessionKey, "runId": d.idempotencyKey,
            "executionBinding": binding, "resultRetentionExpiresAt": NSNull()]
        if status == "started" {
            for key in ["resolvedModel", "resolvedThinking", "degraded", "fallbackReason", "isolationApplied", "nonprojectionApplied"] { object[key] = binding[key] }
        }
        if status == "expired" { object.removeValue(forKey: "resultRetentionExpiresAt") }
        if let terminal { object["terminal"] = terminal; object["resultRetentionExpiresAt"] = 1_800_000_000_000 }
        if status == "notFound" { object = ["status": "notFound"] }
        return try JSONDecoder().decode(IncomingPayload.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func ack(_ d: MeetingMinutesExecutionState.Dispatch) throws -> MinutesExecutionAck {
        try MinutesExecutionAck.validate(response(d), expected: d.request)
    }

    private func answer(_ title: String) -> MeetingMinutesExecutionState.Outcome {
        .answer(MeetingMinutes(title: title, summary: title, topics: [], decisions: [], actionItems: [],
                              openQuestions: [], evidence: [], attendance: nil, language: nil))
    }
    private func fixture() throws -> (MeetingMinutesJob, MeetingStore, String) {
        let record = MeetingRecord(id: "mtg-ledger", source: "manual", startedAt: 0, endedAt: 10,
            timeZone: "UTC", title: "Ledger", conferenceCode: nil, participants: [], minutesState: "pending", minutesError: nil)
        let segments = (0..<12).map { TranscriptSegment(startSeconds: Double($0), endSeconds: Double($0 + 1), text: "hello \($0) " + String(repeating: "x", count: 60)) }
        let envelope = MeetingMinutesEnvelope.build(record: record, segments: segments)
        let chunks = MeetingMinutes.chunked(envelope, maxCharacters: 300)
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: chunks, completed: [])
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return (job, store, record.id)
    }

    func testReverseCompletionReloadKeepsOrderedResults() throws {
        let (job, store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        var state = try MeetingMinutesExecutionState(job: job)
        let first = try state.reserve(index: 0, sessionKey: "agent:example:main", message: "fixture", store: store, id: id)
        let second = try state.reserve(index: 1, sessionKey: "agent:example:main", message: "fixture", store: store, id: id)
        XCTAssertThrowsError(try state.reserve(index: 2, sessionKey: "agent:example:main", message: "fixture", store: store, id: id))
        try state.acknowledge(second, ack: ack(second), store: store, id: id)
        try state.complete(second, runId: second.idempotencyKey, outcome: answer("second"), store: store, id: id)
        try state.acknowledge(first, ack: ack(first), store: store, id: id)
        try state.complete(first, runId: first.idempotencyKey, outcome: answer("first"), store: store, id: id)
        let restored = try XCTUnwrap(try MeetingMinutesExecutionState.load(store: store, id: id, job: job))
        XCTAssertEqual(Array(restored.orderedOutcomes.prefix(2)), [answer("first"), answer("second")])
    }

    func testStaleOwnerRejectedAndKeyIsPersistedBeforeAck() throws {
        let (job, store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        var state = try MeetingMinutesExecutionState(job: job)
        let dispatch = try state.reserve(index: 0, sessionKey: "agent:example:main", message: "fixture", store: store, id: id)
        let reloaded = try XCTUnwrap(try MeetingMinutesExecutionState.load(store: store, id: id, job: job))
        XCTAssertEqual(reloaded.parts[0].idempotencyKey, dispatch.idempotencyKey)
        XCTAssertEqual(reloaded.parts[0].status, .submitting)
        XCTAssertThrowsError(try state.retry(index: 0, sessionKey: "agent:example:main", message: "fixture", store: store, id: id))
        try state.acknowledge(dispatch, ack: ack(dispatch), store: store, id: id)
        XCTAssertThrowsError(try state.complete(dispatch, runId: "wrong", outcome: .insufficientEvidence, store: store, id: id))
    }

    func testSaveFailureDoesNotAdvanceAuthoritativeState() throws {
        let (job, originalStore, id) = try fixture(); defer { try? FileManager.default.removeItem(at: originalStore.root) }
        var state = try MeetingMinutesExecutionState(job: job)
        let blockedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("block".utf8).write(to: blockedRoot)
        defer { try? FileManager.default.removeItem(at: blockedRoot) }
        let blockedStore = MeetingStore(root: blockedRoot)
        XCTAssertThrowsError(try state.reserve(index: 0, sessionKey: "agent:example:main", message: "fixture", store: blockedStore, id: id))
        XCTAssertEqual(state.parts[0].status, .pending)
        XCTAssertThrowsError(try state.save(store: originalStore, id: id), "failed writer must reload before another write")
    }

    func testMigratedSilentPrefixAndHashBinding() throws {
        var (job, store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        job.completed = [nil]
        var state = try MeetingMinutesExecutionState(job: job)
        try state.save(store: store, id: id)
        let restored = try XCTUnwrap(try MeetingMinutesExecutionState.load(store: store, id: id, job: job))
        XCTAssertEqual(restored.parts[0].outcome, .insufficientEvidence)
        XCTAssertEqual(restored.parts[0].attempt, 0)
        XCTAssertFalse(restored.nextIndices.contains(0))
        let changed = MeetingMinutesJob(fingerprint: job.fingerprint, envelopes: Array(job.envelopes.reversed()), completed: [nil])
        XCTAssertThrowsError(try MeetingMinutesExecutionState.load(store: store, id: id, job: changed))
    }

    func testConfirmedTerminalFailureRequiresExplicitRetryAndNewOwner() throws {
        let (job, store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        var state = try MeetingMinutesExecutionState(job: job)
        let first = try state.reserve(index: 0, sessionKey: "agent:example:main", message: "fixture", store: store, id: id)
        try state.acknowledge(first, ack: ack(first), store: store, id: id)
        try state.failTerminal(first, runId: first.idempotencyKey, code: "timeout", retryable: true, store: store, id: id)
        XCTAssertThrowsError(try state.reserve(index: 0, sessionKey: "agent:example:main", message: "fixture", store: store, id: id))
        XCTAssertThrowsError(try state.retry(index: 0, sessionKey: "agent:example:main", message: "changed", store: store, id: id))
        let retry = try state.retry(index: 0, sessionKey: "agent:example:main", message: "fixture", store: store, id: id)
        XCTAssertNotEqual(retry.idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(retry.attempt, 2)
        XCTAssertThrowsError(try state.acknowledge(first, ack: ack(first), store: store, id: id))
        try state.acknowledge(retry, ack: ack(retry), store: store, id: id)
        try state.failTerminal(retry, runId: retry.idempotencyKey, code: "aborted", retryable: false, store: store, id: id)
        XCTAssertThrowsError(try state.retry(index: 0, sessionKey: "agent:example:main", message: "fixture", store: store, id: id))
    }

    func testMalformedPrivateSidecarAndStaleWriterFailClosed() throws {
        let (job, store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        var state = try MeetingMinutesExecutionState(job: job)
        try state.save(store: store, id: id)
        var stale = try XCTUnwrap(try MeetingMinutesExecutionState.load(store: store, id: id, job: job))
        _ = try state.reserve(index: 0, sessionKey: "agent:example:main", message: "fixture", store: store, id: id)
        XCTAssertThrowsError(try stale.reserve(index: 1, sessionKey: "agent:example:main", message: "fixture", store: store, id: id))
        XCTAssertEqual(try MeetingMinutesExecutionState.load(store: store, id: id, job: job)?.parts[0].status, .submitting)
        let url = store.directory(for: id).appendingPathComponent(MeetingMinutesExecutionState.fileName)
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var parts = value["parts"] as! [[String: Any]]
        parts[0]["status"] = "running" // no runId: malformed, not a resumable run
        value["parts"] = parts
        try JSONSerialization.data(withJSONObject: value).write(to: url)
        XCTAssertThrowsError(try MeetingMinutesExecutionState.load(store: store, id: id, job: job))
        let target = url.appendingPathExtension("target")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try MeetingMinutesExecutionState.load(store: store, id: id, job: job))
    }
    func testLostAckReopensExactRequestAndRecoversTerminalWithoutNewAttempt() throws {
        let (job, store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        var state = try MeetingMinutesExecutionState(job: job)
        let d = try state.reserve(index: 0, sessionKey: "agent:example:main", message: "exact\nCafe\u{301}", store: store, id: id)
        state = try XCTUnwrap(MeetingMinutesExecutionState.load(store: store, id: id, job: job))
        XCTAssertEqual(state.recoverableDispatches, [d])
        for status in ["expired", "notFound"] {
            let read = try MinutesExecutionRead.validate(response(d, status: status), expected: d.request)
            XCTAssertThrowsError(try state.reconcile(d, read: read, store: store, id: id))
            XCTAssertEqual(state.parts[0].status, .submitting)
        }
        let terminal = try MinutesExecutionRead.validate(response(d, status: "terminal", terminal: ["kind": "answer", "answer": "fixture"]), expected: d.request)
        try state.reconcile(d, read: terminal, store: store, id: id)
        try state.complete(d, runId: d.idempotencyKey, outcome: .insufficientEvidence, store: store, id: id)
        let restored = try XCTUnwrap(MeetingMinutesExecutionState.load(store: store, id: id, job: job))
        XCTAssertEqual(restored.parts[0].attempt, 1)
        XCTAssertEqual(restored.parts[0].status, .completed)
        XCTAssertTrue(restored.parts[0].executionBinding!.matches(d.request))
        let url = store.directory(for: id).appendingPathComponent(MeetingMinutesExecutionState.fileName)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var parts = object["parts"] as! [[String: Any]]
        var request = parts[0]["request"] as! [String: Any]
        request["message"] = "different"; parts[0]["request"] = request; object["parts"] = parts
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try MeetingMinutesExecutionState.load(store: store, id: id, job: job))
    }

}
