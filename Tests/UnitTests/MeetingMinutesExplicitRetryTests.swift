import XCTest
@testable import ClawGate

final class MeetingMinutesExplicitRetryTests: XCTestCase {
    func testConfirmedRetryUsesExactStoredRequestAndRejectsOldTicket() async throws {
        let (record, job, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try job.save(store: store, id: record.id)
        var state = try MeetingMinutesExecutionState(job: job)
        let first = try state.reserve(index: 0, sessionKey: "agent:retry:main", message: "exact frozen prompt", store: store, id: record.id)
        try state.acknowledge(first, ack: try ack(first), store: store, id: record.id)
        try state.failTerminal(first, runId: first.idempotencyKey, code: "timeout", retryable: true, store: store, id: record.id)

        actor Wire {
            var sends: [MinutesExecutionSendParams] = []
            func send(_ request: MinutesExecutionSendParams) throws -> MinutesExecutionAck {
                sends.append(request)
                return try ack(request)
            }
            func count() -> Int { sends.count }
            func latest() -> MinutesExecutionSendParams? { sends.last }
            private func ack(_ request: MinutesExecutionSendParams) throws -> MinutesExecutionAck {
                let binding: [String: Any] = ["version": 1, "requestFingerprintScheme": MinutesRequestFingerprint.scheme,
                    "requestFingerprint": try request.requestFingerprint(), "resolvedModel": MinutesExecutionSendParams.model,
                    "resolvedThinking": "high", "degraded": false, "fallbackReason": NSNull(),
                    "isolationApplied": true, "nonprojectionApplied": true, "retentionApplied": true]
                var object: [String: Any] = ["status": "started", "sessionKey": request.sessionKey,
                    "runId": request.idempotencyKey, "executionBinding": binding,
                    "resultRetentionExpiresAt": NSNull()]
                for key in ["resolvedModel", "resolvedThinking", "degraded", "fallbackReason", "isolationApplied", "nonprojectionApplied"] { object[key] = binding[key] }
                let payload = try JSONDecoder().decode(IncomingPayload.self, from: JSONSerialization.data(withJSONObject: object))
                return try MinutesExecutionAck.validate(payload, expected: request)
            }
        }
        let wire = Wire()
        let executor = try MeetingMinutesExecutor(job: job, store: store, id: record.id, sessionKey: "agent:retry:main",
            send: { try await wire.send($0) }, read: { _ in throw URLError(.badServerResponse) })
        let initialTickets = await executor.retryTickets()
        let ticket = try XCTUnwrap(initialTickets.first)
        XCTAssertEqual(ticket.idempotencyKey, first.idempotencyKey)
        let retryResult = try await executor.retryConfirmedFailure(ticket: ticket)
        XCTAssertEqual(retryResult, .admitted)
        let latest = await wire.latest()
        let retried = try XCTUnwrap(latest)
        XCTAssertEqual(retried.message, "exact frozen prompt")
        XCTAssertEqual(retried.sessionKey, "agent:retry:main")
        XCTAssertNotEqual(retried.idempotencyKey, first.idempotencyKey)
        let ticketsAfterRetry = await executor.retryTickets()
        XCTAssertTrue(ticketsAfterRetry.isEmpty)
        do {
            _ = try await executor.retryConfirmedFailure(ticket: ticket)
            XCTFail("a stale ticket must not send")
        } catch { }
        let sendCount = await wire.count()
        XCTAssertEqual(sendCount, 1)
    }

    func testNonterminalAndNonRetryableFailuresHaveNoTickets() async throws {
        let (record, job, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try job.save(store: store, id: record.id)
        var state = try MeetingMinutesExecutionState(job: job)
        let dispatch = try state.reserve(index: 0, sessionKey: "agent:retry:main", message: "prompt", store: store, id: record.id)
        try state.acknowledge(dispatch, ack: try ack(dispatch), store: store, id: record.id)
        let runningExecutor = try MeetingMinutesExecutor(job: job, store: store, id: record.id, sessionKey: "agent:retry:main",
            send: { _ in throw URLError(.badServerResponse) }, read: { _ in throw URLError(.badServerResponse) })
        let tickets = await runningExecutor.retryTickets()
        XCTAssertTrue(tickets.isEmpty)
        try state.failTerminal(dispatch, runId: dispatch.idempotencyKey, code: "aborted", retryable: false, store: store, id: record.id)
        let nonRetryable = try MeetingMinutesExecutor(job: job, store: store, id: record.id, sessionKey: "agent:retry:main",
            send: { _ in XCTFail("non-retryable failure must not send"); throw URLError(.badServerResponse) },
            read: { _ in throw URLError(.badServerResponse) })
        let nonRetryableTickets = await nonRetryable.retryTickets()
        XCTAssertTrue(nonRetryableTickets.isEmpty)
    }

    func testExplicitRetryAdmissionRejectionIsNotAnUnknownAck() async throws {
        let (record, job, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try job.save(store: store, id: record.id)
        var state = try MeetingMinutesExecutionState(job: job)
        let first = try state.reserve(index: 0, sessionKey: "agent:retry:main", message: "frozen",
                                      store: store, id: record.id)
        try state.acknowledge(first, ack: ack(first), store: store, id: record.id)
        try state.failTerminal(first, runId: first.idempotencyKey, code: "timeout",
                               retryable: true, store: store, id: record.id)
        let executor = try MeetingMinutesExecutor(job: job, store: store, id: record.id,
            sessionKey: "agent:retry:main",
            send: { _ in throw MinutesExecutionTransportError.admissionRejected },
            read: { _ in XCTFail("rejected admission has no result to read"); throw URLError(.badServerResponse) })
        let tickets = await executor.retryTickets()
        let outcome = try await executor.retryConfirmedFailure(ticket: XCTUnwrap(tickets.first))
        XCTAssertEqual(outcome, .admissionRejected)
        let saved = try XCTUnwrap(MeetingMinutesExecutionState.load(store: store, id: record.id, job: job))
        XCTAssertEqual(saved.parts[0].status, .admissionRejected)
        XCTAssertEqual(saved.parts[0].attempt, 2)
        XCTAssertFalse(saved.parts[0].retryable)
        XCTAssertNil(saved.parts[0].executionBinding)
    }

    private func fixture() throws -> (MeetingRecord, MeetingMinutesJob, MeetingStore) {
        let record = MeetingRecord(id: "retry-fixture", source: "manual", startedAt: 0, endedAt: 1,
                                   timeZone: "UTC", title: "Retry", conferenceCode: nil,
                                   participants: [], minutesState: "pending", minutesError: nil)
        let envelope = MeetingMinutesEnvelope.build(record: record,
            segments: [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "source")])
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: [envelope], completed: [])
        return (record, job, MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }

    private func ack(_ dispatch: MeetingMinutesExecutionState.Dispatch) throws -> MinutesExecutionAck {
        try ack(dispatch.request)
    }

    private func ack(_ request: MinutesExecutionSendParams) throws -> MinutesExecutionAck {
        let binding: [String: Any] = ["version": 1, "requestFingerprintScheme": MinutesRequestFingerprint.scheme,
            "requestFingerprint": try request.requestFingerprint(), "resolvedModel": MinutesExecutionSendParams.model,
            "resolvedThinking": "high", "degraded": false, "fallbackReason": NSNull(),
            "isolationApplied": true, "nonprojectionApplied": true, "retentionApplied": true]
        var object: [String: Any] = ["status": "started", "sessionKey": request.sessionKey,
            "runId": request.idempotencyKey, "executionBinding": binding, "resultRetentionExpiresAt": NSNull()]
        for key in ["resolvedModel", "resolvedThinking", "degraded", "fallbackReason", "isolationApplied", "nonprojectionApplied"] { object[key] = binding[key] }
        let payload = try JSONDecoder().decode(IncomingPayload.self, from: JSONSerialization.data(withJSONObject: object))
        return try MinutesExecutionAck.validate(payload, expected: request)
    }
}
