import XCTest
import CryptoKit
@testable import ClawGate

final class MeetingMinutesExecutorTests: XCTestCase {
    private actor Wire {
        var sends: [MinutesExecutionSendParams] = []
        var barrier: CheckedContinuation<Void, Never>?
        var reads = 0

        func send(_ request: MinutesExecutionSendParams) async throws -> MinutesExecutionAck {
            sends.append(request)
            let first = sends.count == 1
            if first { await withCheckedContinuation { barrier = $0 } }
            else { barrier?.resume(); barrier = nil }
            if first { throw URLError(.networkConnectionLost) }
            return try MinutesExecutionAck.validate(payload(request, status: "started"), expected: request)
        }
        func read(_ request: MinutesExecutionSendParams) throws -> MinutesExecutionRead {
            reads += 1
            // Successful independent terminal results; no model execution.
            return try MinutesExecutionRead.validate(payload(request, status: "terminal"), expected: request)
        }
        func payload(_ request: MinutesExecutionSendParams, status: String) throws -> IncomingPayload {
            let binding: [String: Any] = ["version": 1, "requestFingerprintScheme": MinutesRequestFingerprint.scheme,
                "requestFingerprint": try request.requestFingerprint(), "resolvedModel": MinutesExecutionSendParams.model,
                "resolvedThinking": "high", "degraded": false, "fallbackReason": NSNull(),
                "isolationApplied": true, "nonprojectionApplied": true, "retentionApplied": true]
            var object: [String: Any] = ["status": status, "sessionKey": request.sessionKey,
                "runId": request.idempotencyKey, "executionBinding": binding, "resultRetentionExpiresAt": NSNull()]
            if status == "started" {
                for key in ["resolvedModel", "resolvedThinking", "degraded", "fallbackReason", "isolationApplied", "nonprojectionApplied"] { object[key] = binding[key] }
            } else {
                let text = "{\"outcome\":\"insufficientEvidence\",\"contextDecision\":{\"policyVersion\":\"\(MeetingMinutesPrompt.policyVersion)\"}}"
                object["terminal"] = ["kind": "answer", "answer": text]
                object["resultRetentionExpiresAt"] = 1_800_000_000_000
            }
            return try JSONDecoder().decode(IncomingPayload.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    func testSinglePartAdmissionBudgetSurvivesReopenAndExactPilotRevision() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let record = MeetingRecord(id: "mtg-pilot", source: "manual", startedAt: 0, endedAt: 20,
            timeZone: "UTC", title: "Fixture", conferenceCode: nil, participants: [], minutesState: "pending", minutesError: nil)
        let segments = (0..<8).map { TranscriptSegment(startSeconds: Double($0), endSeconds: Double($0 + 1), text: String(repeating: "x", count: 100)) }
        let envelope = MeetingMinutesEnvelope.build(record: record, segments: segments)
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: MeetingMinutes.chunked(envelope, maxCharacters: 300), completed: [])
        XCTAssertGreaterThan(job.envelopes.count, 1)
        let suite = "minutes-pilot-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(MeetingMinutesPilot.load(defaults: defaults))
        try job.save(store: store, id: record.id)
        let jobBytes = try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-job.json"))
        let jobHash = SHA256.hash(data: jobBytes).map { String(format: "%02x", $0) }.joined()
        defaults.set(["version": 1, "meetingID": record.id,
            "jobSHA256": jobHash],
            forKey: MeetingMinutesPilot.defaultsKey)
        let pilot = try XCTUnwrap(MeetingMinutesPilot.load(defaults: defaults))
        XCTAssertTrue(pilot.matches(store: store, id: record.id, job: job))
        let fresh = MeetingMinutesJob.updating(envelope, previous: job)
        XCTAssertFalse(pilot.matches(store: store, id: record.id, job: fresh))
        defaults.set(["version": 2, "meetingID": record.id, "jobSHA256": jobHash, "mode": "boundedMeeting"],
                     forKey: MeetingMinutesPilot.defaultsKey)
        let bounded = try XCTUnwrap(MeetingMinutesPilot.load(defaults: defaults))
        XCTAssertEqual(bounded.mode, .boundedMeeting)
        XCTAssertTrue(bounded.matches(store: store, id: record.id, job: job))
        let wire = Wire()
        let executor = try MeetingMinutesExecutor(job: job, store: store, id: record.id, sessionKey: "agent:example:main",
            send: { request in try await MinutesExecutionAck.validate(wire.payload(request, status: "started"), expected: request) },
            read: { try await wire.read($0) })
        let first = try await executor.step(maxConcurrentParts: 1, maximumStartedParts: 1)
        XCTAssertEqual(first.live, 1); XCTAssertTrue(first.admissionLimitReached)
        let restored = try MeetingMinutesExecutor(job: job, store: store, id: record.id, sessionKey: "agent:example:main",
            send: { _ in XCTFail("one-part pilot may not send a second part after reopen"); throw URLError(.badServerResponse) },
            read: { try await wire.read($0) })
        let recovered = try await restored.step(maxConcurrentParts: 1, maximumStartedParts: 1)
        XCTAssertEqual(recovered.completed, 1); XCTAssertEqual(recovered.live, 0)
        let held = try await restored.step(maxConcurrentParts: 1, maximumStartedParts: 1)
        XCTAssertEqual(held.completed, 1); XCTAssertEqual(held.live, 0)
        XCTAssertTrue(held.admissionLimitReached)
    }

    func testTwoReservationsLostAckAndReopenUseReadOnlyRecovery() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let record = MeetingRecord(id: "mtg-executor", source: "manual", startedAt: 0, endedAt: 20,
            timeZone: "UTC", title: "Fixture", conferenceCode: nil, participants: [], minutesState: "pending", minutesError: nil)
        let segments = (0..<12).map { TranscriptSegment(startSeconds: Double($0), endSeconds: Double($0 + 1), text: String(repeating: "x", count: 100)) }
        let envelope = MeetingMinutesEnvelope.build(record: record, segments: segments)
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: MeetingMinutes.chunked(envelope, maxCharacters: 300), completed: [])
        XCTAssertGreaterThan(job.envelopes.count, 2)
        let wire = Wire()
        let executor = try MeetingMinutesExecutor(job: job, store: store, id: record.id, sessionKey: "agent:example:main",
            send: { try await wire.send($0) }, read: { try await wire.read($0) })
        let first = try await executor.step()
        XCTAssertEqual(first.live, 2); XCTAssertEqual(first.unresolvedIndices.count, 1)
        let sends = await wire.sends
        XCTAssertEqual(sends.count, 2)
        XCTAssertNotEqual(sends[0].idempotencyKey, sends[1].idempotencyKey)
        let misbound = try MeetingMinutesExecutor(job: job, store: store, id: record.id, sessionKey: "agent:example:main",
            send: { _ in XCTFail("recovery must not send"); throw URLError(.badServerResponse) },
            read: { request in
                let other = MinutesExecutionSendParams(sessionKey: request.sessionKey, message: request.message + "x", idempotencyKey: request.idempotencyKey)
                return try await wire.read(other)
            })
        let rejected = try await misbound.step()
        XCTAssertEqual(rejected.completed, 0); XCTAssertEqual(rejected.unresolvedIndices.count, 2)
        let restored = try MeetingMinutesExecutor(job: job, store: store, id: record.id, sessionKey: "agent:example:main",
            send: { _ in XCTFail("recovery must not send"); throw URLError(.badServerResponse) },
            read: { try await wire.read($0) })
        let recovered = try await restored.step()
        XCTAssertEqual(recovered.completed, 2); XCTAssertEqual(recovered.live, 0)
        XCTAssertTrue(recovered.unresolvedIndices.isEmpty)
        let outcomes = await restored.orderedOutcomes()
        XCTAssertEqual(Array(outcomes.prefix(2)), [.insufficientEvidence, .insufficientEvidence])
        let count = await wire.sends.count; XCTAssertEqual(count, 2)
    }
}
