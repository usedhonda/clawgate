import XCTest
@testable import ClawGate

final class MeetingMinutesAdmissionTests: XCTestCase {
    func testInvalidRequestAdmissionRejectionPersistsWithoutBindingOrResend() async throws {
        let (record, job, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try job.save(store: store, id: record.id)

        let executor = try MeetingMinutesExecutor(job: job, store: store, id: record.id,
            sessionKey: "agent:admission:main",
            send: { _ in throw MinutesExecutionTransportError.admissionRejected },
            read: { _ in XCTFail("pre-admission rejection must not read a result"); throw URLError(.badServerResponse) })
        let first = try await executor.step(maxConcurrentParts: 1)
        XCTAssertEqual(first.admissionRejectedIndices, [0])
        XCTAssertEqual(first.live, 0)
        XCTAssertTrue(first.unresolvedIndices.isEmpty)
        let saved = try XCTUnwrap(MeetingMinutesExecutionState.load(store: store, id: record.id, job: job))
        XCTAssertNotNil(saved.parts[0].request)
        XCTAssertNotNil(saved.parts[0].requestFingerprint)
        XCTAssertNil(saved.parts[0].executionBinding)
        XCTAssertNil(saved.parts[0].runId)
        XCTAssertNil(saved.parts[0].outcome)
        XCTAssertFalse(saved.parts[0].retryable)
        XCTAssertEqual(MeetingMinutesExecutionProgress(ledger: saved).phaseLabel,
                       MeetingMinutesExecutionProgress.admissionRejectedMessage)

        let restored = try MeetingMinutesExecutor(job: job, store: store, id: record.id,
            sessionKey: "agent:admission:main",
            send: { _ in XCTFail("a definitive pre-admission rejection must never resend"); throw URLError(.badServerResponse) },
            read: { _ in XCTFail("a pre-admission rejection has no owner to recover"); throw URLError(.badServerResponse) })
        let reopened = try await restored.step(maxConcurrentParts: 1)
        XCTAssertEqual(reopened.admissionRejectedIndices, [0])
        XCTAssertEqual(reopened.live, 0)
        XCTAssertTrue(reopened.unresolvedIndices.isEmpty)
    }

    func testUnknownSendFailureRemainsRecoverableAndDoesNotResend() async throws {
        let (record, job, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try job.save(store: store, id: record.id)

        let executor = try MeetingMinutesExecutor(job: job, store: store, id: record.id,
            sessionKey: "agent:admission:main",
            send: { _ in throw URLError(.timedOut) },
            read: { _ in throw URLError(.timedOut) })
        let first = try await executor.step(maxConcurrentParts: 1)
        XCTAssertEqual(first.unresolvedIndices, [0])
        XCTAssertTrue(first.admissionRejectedIndices.isEmpty)

        let restored = try MeetingMinutesExecutor(job: job, store: store, id: record.id,
            sessionKey: "agent:admission:main",
            send: { _ in XCTFail("unknown send failure remains read-recovery only"); throw URLError(.badServerResponse) },
            read: { _ in throw URLError(.timedOut) })
        let reopened = try await restored.step(maxConcurrentParts: 1)
        XCTAssertEqual(reopened.unresolvedIndices, [0])
        XCTAssertTrue(reopened.admissionRejectedIndices.isEmpty)
    }

    private func fixture() throws -> (MeetingRecord, MeetingMinutesJob, MeetingStore) {
        let record = MeetingRecord(id: "admission-fixture", source: "manual", startedAt: 0,
            endedAt: 1, timeZone: "UTC", title: "Admission", conferenceCode: nil,
            participants: [], minutesState: "pending", minutesError: nil)
        let envelope = MeetingMinutesEnvelope.build(record: record,
            segments: [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "source")])
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope),
            envelopes: [envelope, envelope], completed: [])
        return (record, job, MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)))
    }
}
