import XCTest
@testable import ClawGate

final class MeetingMinutesConnectivityTests: XCTestCase {
    private var store: MeetingStore!
    private var model: PetModel!

    override func setUp() {
        super.setUp()
        store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        model = PetModel()
        model.setMeetingStoreForTesting(store)
        model.setSessionKeyForTesting("agent:fixture:main")
        model.setConnectionStateForTesting(.connected)
        model.suppressLogSendForTesting = true
        model.meetingTranscriptProvider = { _ in
            (0..<30).map { index in
                var segment = TranscriptSegment(startSeconds: Double(index), endSeconds: Double(index + 1),
                    text: String(repeating: "議題と担当を確認した。", count: 80))
                segment.capturedAt = 1_790_000_000 + Double(index * 10)
                return segment
            }
        }
    }

    override func tearDown() {
        model.cleanup()
        try? FileManager.default.removeItem(at: store.root)
        super.tearDown()
    }

    private func meeting() -> MeetingRecord {
        let record = MeetingRecord(id: "mtg-offline-fixture", source: "meet", startedAt: 1_790_000_000,
            endedAt: 1_790_003_600, timeZone: "UTC", title: nil, conferenceCode: nil, participants: [],
            minutesState: "none", minutesError: nil)
        store.save(record)
        return record
    }

    private func recoverNetwork() {
        let restored = expectation(description: "connection recovery scan finished")
        model.minutesRecoveryDidFinishForTesting = { restored.fulfill() }
        model.setMinutesNetworkAvailableForTesting(false)
        model.setMinutesNetworkAvailableForTesting(true)
        wait(for: [restored], timeout: 10)
        model.minutesRecoveryDidFinishForTesting = nil
        waitForMinutesPreparation(of: model)
    }

    func testOfflinePreparationPersistsWithoutSendingThenResumesOnConnection() throws {
        let record = meeting()
        model.setMinutesNetworkAvailableForTesting(false)
        model.requestMinutes(for: record)
        waitForMinutesPreparation(of: model)
        let before = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        XCTAssertGreaterThan(before.envelopes.count, 1)
        XCTAssertNil(model.pendingMinutesMeetingIDForTesting)
        XCTAssertNil(model.minutesAttemptsForTesting[record.id])
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "pending")
        recoverNetwork()
        XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, record.id)
        XCTAssertEqual(model.minutesAttemptsForTesting[record.id], 1)
        XCTAssertEqual(MeetingMinutesJob.load(store: store, id: record.id)?.fingerprint, before.fingerprint)
    }

    func testRecoveryWaitSurvivesReloadAndPreservesCompletedCheckpoint() throws {
        let record = meeting()
        model.requestMinutes(for: record)
        waitForMinutesPreparation(of: model)
        var before = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        before.completed = [nil]
        try before.save(store: store, id: record.id)
        model.setMinutesAttemptsForTesting(PetModel.minutesMaxAttempts, id: record.id)
        model.acknowledgeSharedSummonForTesting(runId: "offline-run")
        model.handleEvent(.runFailed(owner: OpenClawEventOwnerIdentity(messageId: "offline-run", runId: "offline-run"),
                                    reason: "OpenClaw couldn't finish this reply"))
        let saved = expectation(description: "recovery wait persisted")
        DispatchQueue.main.async { self.model.afterMinutesPreparationForTesting { saved.fulfill() } }
        wait(for: [saved], timeout: 10)
        let waiting = try XCTUnwrap(MeetingMinutesJob.load(store: MeetingStore(root: store.root), id: record.id))
        XCTAssertEqual(waiting.waitingForConnectivity, true)
        XCTAssertNotNil(waiting.connectivityRetryAfter)
        XCTAssertEqual(waiting.completed, before.completed)
        XCTAssertEqual(waiting.fingerprint, before.fingerprint)
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "pending")
        XCTAssertNil(model.pendingMinutesMeetingIDForTesting)
        recoverNetwork()
        let after = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        XCTAssertNil(after.waitingForConnectivity)
        XCTAssertNil(after.connectivityRetryAfter)
        XCTAssertEqual(after.completed, before.completed)
        XCTAssertEqual(after.fingerprint, before.fingerprint)
        XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, record.id)
        XCTAssertEqual(model.minutesAttemptsForTesting[record.id], 1)
    }

    func testDisconnectDoesNotCarryExhaustedAttemptBudgetIntoReconnect() throws {
        let record = meeting()
        model.requestMinutes(for: record)
        waitForMinutesPreparation(of: model)
        model.setMinutesAttemptsForTesting(PetModel.minutesMaxAttempts, id: record.id)
        model.handleEvent(.disconnected(reason: nil))
        let disconnected = expectation(description: "disconnect processed")
        DispatchQueue.main.async { disconnected.fulfill() }
        wait(for: [disconnected], timeout: 2)
        XCTAssertEqual(model.minutesAttemptsForTesting[record.id], 0)
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "pending")
        model.setConnectionStateForTesting(.connected)
        recoverNetwork()
        XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, record.id)
        XCTAssertEqual(model.minutesAttemptsForTesting[record.id], 1)
    }

    func testOnlyTransientNetworkAndServiceFailuresWaitForRecovery() {
        XCTAssertTrue(PetModel.isRecoverableMinutesNetworkError(.notConnectedToInternet))
        XCTAssertTrue(PetModel.isRecoverableMinutesNetworkError(.networkConnectionLost))
        XCTAssertFalse(PetModel.isRecoverableMinutesNetworkError(.badURL))
        XCTAssertTrue(PetModel.isRecoverableMinutesServiceFailure("OpenClaw couldn't finish this reply"))
        XCTAssertFalse(PetModel.isRecoverableMinutesServiceFailure("aborted"))
        XCTAssertFalse(PetModel.isRecoverableMinutesServiceFailure("invalidEvidence"))
        XCTAssertFalse(PetModel.isRecoverableMinutesServiceFailure("modelMismatch"))
    }

    func testStaleFailureCannotMarkAnotherSourceRevisionWaiting() throws {
        let record = meeting()
        model.setMinutesNetworkAvailableForTesting(false)
        model.requestMinutes(for: record)
        waitForMinutesPreparation(of: model)
        let current = try XCTUnwrap(store.load(id: record.id))
        let url = store.directory(for: record.id).appendingPathComponent("minutes-job.json")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try MeetingMinutesPreparation.setConnectivityWait(true, record: current,
            store: store, expectedFingerprint: "stale-fingerprint"))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testMetadataRefreshPreservesRecoveryWaitAndDeadline() throws {
        let record = meeting()
        model.setMinutesNetworkAvailableForTesting(false)
        model.requestMinutes(for: record)
        waitForMinutesPreparation(of: model)
        var waiting = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        waiting.waitingForConnectivity = true
        waiting.connectivityRetryAfter = Date(timeIntervalSince1970: 2_000_000_000)
        waiting.completed = [nil]
        let envelope = try XCTUnwrap(waiting.frozenEnvelope)
        XCTAssertEqual(MeetingMinutes.chunked(envelope).count, waiting.envelopes.count)
        let refreshed = waiting.refreshingMetadata(from: envelope)
        XCTAssertEqual(refreshed.waitingForConnectivity, true)
        XCTAssertEqual(refreshed.connectivityRetryAfter, waiting.connectivityRetryAfter)
        XCTAssertEqual(refreshed.completed, waiting.completed)
        XCTAssertEqual(refreshed.fingerprint, waiting.fingerprint)
    }

    func testRepeatedServiceFailureWaitsForARealConnectionChange() throws {
        let record = meeting()
        model.setMinutesNetworkAvailableForTesting(false)
        model.requestMinutes(for: record)
        waitForMinutesPreparation(of: model)
        let pending = try XCTUnwrap(store.load(id: record.id))
        let firstProbe = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(try MeetingMinutesPreparation.setConnectivityWait(true, record: pending,
            store: store, retryAfter: firstProbe))
        XCTAssertTrue(try MeetingMinutesPreparation.setConnectivityWait(false, record: pending,
            store: store, retryAfter: firstProbe))
        XCTAssertTrue(try MeetingMinutesPreparation.setConnectivityWait(true, record: pending,
            store: store, retryAfter: Date().addingTimeInterval(300)))
        let waiting = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        XCTAssertEqual(waiting.waitingForConnectivity, true)
        XCTAssertEqual(waiting.connectivityRetryAfter, .distantFuture)
        XCTAssertTrue(try MeetingMinutesPreparation.setConnectivityWait(false, record: pending, store: store))
        let reconnected = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        XCTAssertNil(reconnected.waitingForConnectivity)
        XCTAssertNil(reconnected.connectivityRetryAfter)
        XCTAssertEqual(reconnected.fingerprint, waiting.fingerprint)
        XCTAssertEqual(reconnected.completed, waiting.completed)
    }
}
