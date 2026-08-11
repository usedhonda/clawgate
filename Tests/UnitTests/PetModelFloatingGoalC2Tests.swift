import XCTest
import AppKit
@testable import ClawGate

final class PetModelFloatingGoalC2Tests: XCTestCase {
    private var originalTimeout: TimeInterval = 0

    override func setUp() {
        super.setUp()
        originalTimeout = PetModel.summonReplyTimeoutSeconds
        PetModel.summonReplyTimeoutSeconds = 5
    }

    override func tearDown() {
        PetModel.summonReplyTimeoutSeconds = originalTimeout
        super.tearDown()
    }

    func testSharedSummonAdmissionPreservesOriginalOwner() throws {
        let model = PetModel()
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        _ = model.beginSharedSummonAwaitingAckForTesting(source: "ask")
        let token = try XCTUnwrap(model.summonWatchdogTokenForTesting)
        model.claimSharedSummonForTesting(source: "omakase")

        XCTAssertEqual(model.pendingSummonSource, "ask")
        XCTAssertEqual(model.summonWatchdogTokenForTesting, token)
        model.cleanup()
    }

    func testSharedEventsBeforeAckDoNotMutateStreamingState() async throws {
        let model = PetModel()
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true
        _ = model.beginSharedSummonAwaitingAckForTesting(source: "ask")

        model.handleEvent(.delta(
            messageId: OpenClawEventOwnerIdentity(messageId: "m1", runId: "run-A"),
            text: "stale"))
        model.handleEvent(.messageComplete(
            messageId: OpenClawEventOwnerIdentity(messageId: "m1", runId: "run-A")))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(model.isStreaming)
        XCTAssertTrue(model.streamingText.isEmpty)
        XCTAssertTrue(model.summonResults.isEmpty)
        XCTAssertEqual(model.pendingSummonSource, "ask")
        model.cleanup()
    }

    func testMatchingRunFinalizesWhenMessageIdDiffersFromRunId() async throws {
        let model = PetModel()
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true
        model.claimSharedSummonForTesting(source: "ask")
        model.pendingSummonRunId = "run-A"

        model.handleEvent(.delta(
            messageId: OpenClawEventOwnerIdentity(messageId: "m1", runId: "run-A"),
            text: "answer"))
        model.handleEvent(.messageComplete(
            messageId: OpenClawEventOwnerIdentity(messageId: "m1", runId: "run-A")))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.summonResults.filter { $0.source == "ask" }.count, 1)
        XCTAssertFalse(model.isSummonBusy)
        model.cleanup()
    }

    func testWrongRunAfterAckLeavesOwnerUntouchedThenMatchingRunFinalizesOnce() async throws {
        let model = PetModel()
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true
        let token = try XCTUnwrap(model.startSharedSummonForTesting(source: "ask"))
        model.pendingSummonRunId = "run-A"

        model.handleEvent(.delta(
            messageId: OpenClawEventOwnerIdentity(messageId: "wrong-message", runId: "run-B"),
            text: "wrong"))
        model.handleEvent(.messageComplete(
            messageId: OpenClawEventOwnerIdentity(messageId: "wrong-message", runId: "run-B")))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.pendingSummonSource, "ask")
        XCTAssertEqual(model.summonWatchdogTokenForTesting, token)
        XCTAssertTrue(model.summonResults.isEmpty)
        XCTAssertTrue(model.streamingText.isEmpty)

        model.handleEvent(.delta(
            messageId: OpenClawEventOwnerIdentity(messageId: "real-message", runId: "run-A"),
            text: "right"))
        model.handleEvent(.messageComplete(
            messageId: OpenClawEventOwnerIdentity(messageId: "real-message", runId: "run-A")))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.summonResults.filter { $0.source == "ask" }.count, 1)
        XCTAssertFalse(model.isSummonBusy)
        model.cleanup()
    }

    func testAskOmakaseDraftAdmissionDispatchesOnlyCurrentOwner() throws {
        let model = PetModel()
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let owner = try XCTUnwrap(model.startSharedSummonForTesting(source: "ask"))
        XCTAssertNil(model.startSharedSummonForTesting(source: "omakase"))
        XCTAssertNil(model.startSharedSummonForTesting(source: "draft_pr"))
        XCTAssertEqual(model.sharedSummonDispatchCountForTesting, 1)
        XCTAssertEqual(model.pendingSummonSource, "ask")
        XCTAssertEqual(model.summonWatchdogTokenForTesting, owner)
        model.cleanup()
    }

    func testDelayedDraftWorkerCompletionCannotDispatchAfterOwnerChanges() throws {
        let model = PetModel()
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let draftOwner = try XCTUnwrap(model.startSharedSummonForTesting(source: "draft_pr"))
        model.releaseSharedSummonForTesting(token: draftOwner)
        _ = try XCTUnwrap(model.startSharedSummonForTesting(source: "ask"))
        let dispatchCount = model.sharedSummonDispatchCountForTesting

        model.completeDraftPRWorkerForTesting(token: draftOwner)

        XCTAssertEqual(model.sharedSummonDispatchCountForTesting, dispatchCount)
        XCTAssertEqual(model.pendingSummonSource, "ask")
        model.cleanup()
    }

    func testLateOmakasePlacementCannotMutateOrReleaseNewOwner() throws {
        let model = PetModel()
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let omakaseOwner = try XCTUnwrap(model.startSharedSummonForTesting(source: "omakase"))
        model.beginOmakaseDraftPlacementForTesting(token: omakaseOwner)
        _ = try XCTUnwrap(model.startSharedSummonForTesting(source: "ask"))
        let resultCount = model.summonResults.count

        model.completeOmakaseDraftPlacementForTesting(token: omakaseOwner)

        XCTAssertEqual(model.summonResults.count, resultCount)
        XCTAssertEqual(model.pendingSummonSource, "ask")
        model.cleanup()
    }

}
