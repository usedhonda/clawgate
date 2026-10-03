import XCTest
@testable import ClawGate

final class MeetingMinutesOverviewExecutorTests: XCTestCase {
    func testLostAckThenReadPublishesOnceAndReopenDoesNotSend() async throws {
        let record = MeetingRecord(id: "overview-fixture", source: "manual", startedAt: 0,
                                   endedAt: 20, timeZone: "UTC", title: "Fixture",
                                   conferenceCode: nil, participants: [], minutesState: "pending", minutesError: nil)
        let envelope = MeetingMinutesEnvelope.build(record: record,
            segments: [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: String(repeating: "a", count: 160)),
                       TranscriptSegment(startSeconds: 1, endSeconds: 2, text: String(repeating: "b", count: 160))])
        let envelopes = MeetingMinutes.chunked(envelope, maxCharacters: 120)
        let answers = envelopes.enumerated().map { index, part in
            let summary = "Part \(index + 1)"
            return MeetingMinutes(title: "Fixture", summary: summary, topics: [], decisions: [],
                actionItems: [], openQuestions: [],
                evidence: [MeetingEvidence(claim: summary, segmentIds: part.segments.map(\.id))],
                attendance: nil, language: nil)
        }
        let fingerprint = MeetingMinutesJob.fingerprint(envelope)
        let frozen = MeetingMinutesJob(fingerprint: fingerprint, envelopes: envelopes,
                                       completed: [])
        let completed = MeetingMinutesJob(fingerprint: fingerprint, envelopes: envelopes,
                                          completed: answers)
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        try frozen.save(store: store, id: record.id)
        let base = try XCTUnwrap(MeetingMinutes.combining(answers)?.boundToCalendarEvent(record.calendarEventID))
        try store.saveValidatedMinutes(base, for: record, job: completed)

        actor Wire {
            var sends = 0
            let evidenceSegmentID: String
            var invalid = false
            init(evidenceSegmentID: String) { self.evidenceSegmentID = evidenceSegmentID }
            func send(_ request: MinutesExecutionSendParams) async throws -> MinutesExecutionAck {
                sends += 1
                throw URLError(.networkConnectionLost)
            }
            func count() -> Int { sends }
            func invalidate() { invalid = true }
            func read(_ request: MinutesExecutionSendParams) async throws -> MinutesExecutionRead {
                let body = invalid
                    ? #"{"policyVersion":"wrong","summary":"bad","summaryEvidence":[],"dues":[]}"#
                    : "{\"policyVersion\":\"meeting-minutes-summary-v1\",\"summary\":\"全体の概要。\",\"summaryEvidence\":[{\"claim\":\"全体の概要。\",\"segmentIds\":[\"\(evidenceSegmentID)\"]}],\"dues\":[]}"
                let binding: [String: Any] = ["version": 1, "requestFingerprintScheme": MinutesRequestFingerprint.scheme,
                    "requestFingerprint": try request.requestFingerprint(), "resolvedModel": MinutesExecutionSendParams.model,
                    "resolvedThinking": "high", "degraded": false, "fallbackReason": NSNull(),
                    "isolationApplied": true, "nonprojectionApplied": true, "retentionApplied": true]
                let object: [String: Any] = ["status": "terminal", "sessionKey": request.sessionKey,
                    "runId": request.idempotencyKey, "executionBinding": binding, "terminal": ["kind": "answer", "answer": body],
                    "resultRetentionExpiresAt": 1_800_000_000_000]
                return try MinutesExecutionRead.validate(
                    JSONDecoder().decode(IncomingPayload.self, from: JSONSerialization.data(withJSONObject: object)),
                    expected: MinutesExecutionSendParams(sessionKey: request.sessionKey, message: request.message, idempotencyKey: request.idempotencyKey))
            }
        }
        let wire = Wire(evidenceSegmentID: try XCTUnwrap(envelopes.first?.segments.first?.id))
        let first = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: store, id: record.id, sessionKey: "agent:overview:main",
            send: { try await wire.send($0) }, read: { try await wire.read($0) })
        let firstState = try await first.step()
        XCTAssertEqual(firstState, .recovering)
        let reopened = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: store, id: record.id, sessionKey: "agent:overview:main",
            send: { _ in XCTFail("recovery must not send"); throw URLError(.badServerResponse) },
            read: { try await wire.read($0) })
        let published = try await reopened.step()
        guard case .completed(let rewritten?) = published else { return XCTFail("overview must publish after recovery") }
        XCTAssertEqual(rewritten.summary, "全体の概要。")
        let sendCount = await wire.count()
        XCTAssertEqual(sendCount, 1)

        let acceptedBytes = try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json"))
        var editedRecord = record
        editedRecord.startedAt += 86_400
        editedRecord.timeZone = "Asia/Tokyo"
        editedRecord.title = "Later calendar metadata"
        editedRecord.calendarEventID = "later-calendar"
        let afterComplete = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: editedRecord, store: store, id: record.id, sessionKey: "agent:overview:main",
            send: { _ in XCTFail("completed overview must not send"); throw URLError(.badServerResponse) },
            read: { _ in XCTFail("completed overview must not read"); throw URLError(.badServerResponse) })
        let repeated = try await afterComplete.step()
        guard case .completed(let same?) = repeated else { return XCTFail("published overview must reopen") }
        XCTAssertEqual(same, rewritten)
        XCTAssertEqual(try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json")), acceptedBytes)

        let invalidStore = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: invalidStore.root) }
        try frozen.save(store: invalidStore, id: record.id)
        try invalidStore.saveValidatedMinutes(base, for: record, job: completed)
        let invalidPath = invalidStore.directory(for: record.id).appendingPathComponent("minutes-accepted.json")
        let beforeInvalid = try Data(contentsOf: invalidPath)
        let invalidWire = Wire(evidenceSegmentID: try XCTUnwrap(envelopes.first?.segments.first?.id))
        await invalidWire.invalidate()
        let invalidExecutor = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: invalidStore, id: record.id, sessionKey: "agent:overview:main",
            send: { try await invalidWire.send($0) }, read: { try await invalidWire.read($0) })
        _ = try await invalidExecutor.step()
        let rejected = try await invalidExecutor.step()
        XCTAssertEqual(rejected, .failed)
        XCTAssertEqual(try Data(contentsOf: invalidPath), beforeInvalid)

        let changedJob = MeetingMinutesJob.updating(envelope, previous: frozen)
        try changedJob.save(store: store, id: record.id)
        let stale = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: store, id: record.id, sessionKey: "agent:overview:main",
            send: { _ in XCTFail("stale overview must not send"); throw URLError(.badServerResponse) },
            read: { _ in XCTFail("stale overview must not read"); throw URLError(.badServerResponse) })
        do {
            _ = try await stale.step()
            XCTFail("stale overview publication must be rejected")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json")), acceptedBytes)
    }
}
