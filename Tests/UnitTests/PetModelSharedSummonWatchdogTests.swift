import XCTest
@testable import ClawGate

/// Reproduces the 2026-07-16 incident: the SHARED summon path (`sendSummon`,
/// used by scene naming / omakase / ask / draft_pr) had no self-recovery when a
/// reply never arrived. If the WS send succeeded but no terminal event ever
/// reached the client (e.g. the reply was emitted during a connection-down
/// window and reconnect never replays missed events), `pendingSummonSource`
/// stayed set forever, and `sendLogInstruction`'s busy-admission gate then
/// refused every subsequent Pet Log action indefinitely (the slot stayed wedged
/// ~24h in production until an app restart). The fix arms a tokenized
/// self-release watchdog on the shared path, mirroring the Log path's existing
/// 180s reply-timeout watchdog while remaining provably independent of it.
final class PetModelSharedSummonWatchdogTests: XCTestCase {
    private var originalSummonReplyTimeoutSeconds: TimeInterval = 0
    private var originalLogAwaitingReplyTimeoutSeconds: TimeInterval = 0
    private var originalLogStoreDir = ""

    override func setUp() {
        super.setUp()
        originalSummonReplyTimeoutSeconds = PetModel.summonReplyTimeoutSeconds
        PetModel.summonReplyTimeoutSeconds = 0.1 // 100ms, shrunk for fast/deterministic tests
        originalLogAwaitingReplyTimeoutSeconds = PetModel.logAwaitingReplyTimeoutSeconds
        PetModel.logAwaitingReplyTimeoutSeconds = 0.1 // 100ms, shrunk for fast/deterministic tests

        // Any "log"/summon completion reached below must never write through to
        // the user's real ~/.clawgate/logs/*.json — redirect to a throwaway temp
        // directory. `dir` is a process-global static: hold the shared semaphore
        // for the entire setUp...tearDown lifetime so a parallel test in another
        // class can't race this override (2026-07-14 real-data-loss incident).
        PetLogStore.testIsolationSemaphore.wait()
        originalLogStoreDir = PetLogStore.dir
        PetLogStore.dir = NSTemporaryDirectory() + "clawgate-test-logs-\(UUID().uuidString)"
    }

    override func tearDown() {
        PetModel.summonReplyTimeoutSeconds = originalSummonReplyTimeoutSeconds
        PetModel.logAwaitingReplyTimeoutSeconds = originalLogAwaitingReplyTimeoutSeconds
        try? FileManager.default.removeItem(atPath: PetLogStore.dir)
        PetLogStore.dir = originalLogStoreDir
        PetLogStore.testIsolationSemaphore.signal()
        super.tearDown()
    }

    private func logEnvelope(instruction: String = "質問まとめ") -> PetLogQueryEnvelope {
        PetLogQueryEnvelope(
            requestId: UUID().uuidString, actionId: "slot-0", instruction: instruction,
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true, segments: []
        )
    }

    /// The incident itself: an auto-triggered scene-naming summon whose reply
    /// never arrives must self-release. Before the fix, this left the summon slot
    /// (and `pendingSceneNamingIDs`) wedged forever, blocking every subsequent
    /// Pet Log action AND tomorrow's auto-naming.
    func testSharedWatchdogReleasesWedgedSceneNamingSlotAndUnblocksLog() async throws {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        // Suppress the real WS send so the shared reply-timeout watchdog is the
        // sole release mechanism — deterministically reproducing "send
        // succeeded, reply never arrived" without a socket racing it.
        model.suppressLogSendForTesting = true

        model.requestSceneNaming(scenes: [(id: "s1", timeLabel: "10:00–10:05", excerpt: "x")])
        XCTAssertTrue(model.isSummonBusy, "scene naming must claim the summon slot")
        XCTAssertEqual(model.pendingSceneNamingIDsForTesting, ["s1"],
                       "scene naming must record its in-flight ids")

        // No terminal WS event ever arrives — let the shrunk shared watchdog fire.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(model.isSummonBusy, "the wedged scene-naming slot must self-release")
        XCTAssertTrue(model.pendingSceneNamingIDsForTesting.isEmpty,
                      "scene-naming ids must be reclaimed so tomorrow's auto-naming isn't blocked")
        XCTAssertEqual(
            model.logReplies.filter { $0.source == "log_scene_naming" || $0.source == "log" }.count, 0,
            "a background scene-naming failure must never surface into the Log pane")
        XCTAssertEqual(model.summonResults.count, 0,
                       "scene naming must not leave a summon-tab entry on timeout")

        // A subsequent Log action must NOT be refused busy now that the slot
        // cleared — it proceeds past admission (creating a log_user prompt).
        model.sendLogInstruction(envelope: logEnvelope())
        XCTAssertFalse(model.logReplies.contains { $0.text.contains("busy") },
                       "Log admission must proceed once the wedged slot is reclaimed")
        XCTAssertTrue(model.logReplies.contains { $0.source == "log_user" },
                      "the Log summon must reach the send path, not be refused")
    }

    /// A stale watchdog firing late must never release a NEWER summon that reused
    /// the slot. Token+source double match is what prevents cross-release.
    func testStaleSharedWatchdogDoesNotReleaseNewerSummon() async throws {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        // First summon claims the slot (watchdog token #1 armed, deadline 0.1s).
        model.claimSharedSummonForTesting(source: "log_scene_naming")
        XCTAssertTrue(model.isSummonBusy)

        // Normal termination BEFORE the timeout: a summon-routed .message clears
        // the slot and nils token #1.
        model.handleEvent(.message(OpenClawChatMessage(role: .assistant, text: "1: 朝会")))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(model.isSummonBusy, "first summon must resolve normally")

        // Immediately claim AGAIN (different source) with a LONGER timeout so the
        // second watchdog's deadline sits well past the first one's — lets us
        // sleep past ONLY the first deadline.
        PetModel.summonReplyTimeoutSeconds = 5.0
        model.claimSharedSummonForTesting(source: "ask")
        XCTAssertEqual(model.pendingSummonSource, "ask")

        // Sleep past the FIRST watchdog's (0.1s) deadline. Its stale closure must
        // no-op: token mismatch AND source mismatch both hold.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(model.isSummonBusy, "the newer summon's slot must still be held")
        XCTAssertEqual(model.pendingSummonSource, "ask",
                       "a stale watchdog must not release a different summon's slot")
    }

    /// A normal reply cancels the watchdog: after a real reply resolves the
    /// summon, a late watchdog must not append a duplicate timeout marker.
    func testNormalReplyCancelsSharedWatchdogNoDuplicateMarker() async throws {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        model.claimSharedSummonForTesting(source: "ask")
        XCTAssertTrue(model.isSummonBusy)

        // Deliver a normal summon-routed reply before the timeout.
        model.handleEvent(.message(OpenClawChatMessage(role: .assistant, text: "real answer")))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(model.isSummonBusy, "the real reply releases the slot")

        // Sleep past the watchdog deadline — it must not append a second entry.
        try await Task.sleep(nanoseconds: 300_000_000)

        let askEntries = model.summonResults.filter { $0.source == "ask" }
        XCTAssertEqual(askEntries.count, 1,
                       "exactly one summon result — no duplicate timeout marker after a real reply")
        XCTAssertEqual(askEntries.first?.text, "real answer")
        XCTAssertFalse(model.summonResults.contains { $0.text.contains("no reply received") },
                       "a cancelled watchdog must not leave a spurious timeout marker")
    }

    /// Independence in both directions: the shared watchdog must never release a
    /// Log summon (which never arms it), and the Log path keeps its own separate
    /// watchdog. Shared=0.1s, log=0.5s: at t≈0.2s the Log summon is still busy
    /// (shared watchdog didn't touch it); after the Log watchdog fires it
    /// releases with its own "no reply received" marker as before.
    func testSharedAndLogWatchdogsAreIndependent() async throws {
        PetModel.logAwaitingReplyTimeoutSeconds = 0.5 // longer than the 0.1s shared timeout

        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        model.sendLogInstruction(envelope: logEnvelope())
        XCTAssertTrue(model.logAwaitingReply)
        XCTAssertTrue(model.isSummonBusy)

        // Past the shared deadline (0.1s) but before the Log deadline (0.5s):
        // the shared watchdog was never armed for a Log summon, so nothing
        // released it.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.isSummonBusy, "the shared watchdog must not release a Log summon")
        XCTAssertTrue(model.logAwaitingReply)
        XCTAssertEqual(model.logReplies.filter { $0.source == "log" }.count, 0,
                       "no shared-path timeout marker may appear for a Log summon")

        // After the Log watchdog fires (t>0.5s): released with its own marker.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(model.isSummonBusy, "the Log watchdog must release its own slot")
        XCTAssertFalse(model.logAwaitingReply)
        let logEntries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(logEntries.count, 1, "exactly the Log watchdog's marker, no shared-path marker")
        XCTAssertTrue(logEntries.first?.text.contains("no reply received") ?? false)
    }

    private enum SummonTestError: Error { case deadSocket }

    /// The send-failure race: a first summon's slot is released and re-claimed by
    /// a NEWER summon before the first send's late throw lands. The stale send's
    /// cleanup must not touch the newer summon's token/source, nor append an error
    /// marker for the superseded request. Token+source match is the guard.
    func testStaleSummonSendFailureDoesNotTouchNewerSummon() async throws {
        // Pin the watchdog well past this synchronous test so it can't race the
        // assertions and release a slot out from under us.
        PetModel.summonReplyTimeoutSeconds = 5.0

        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        // Summon A claims the slot; capture its (soon-to-be stale) token.
        model.claimSharedSummonForTesting(source: "ask")
        let staleToken = try XCTUnwrap(model.summonWatchdogTokenForTesting)

        // A resolves/releases (a normal termination nils its token) — modelling
        // the disconnect-then-reclaim window the fix guards against.
        model.handleEvent(.message(OpenClawChatMessage(role: .assistant, text: "answer")))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(model.isSummonBusy, "summon A must release before B claims")

        // Summon B claims the slot with a DIFFERENT source and a fresh token.
        model.claimSharedSummonForTesting(source: "omakase")
        let currentToken = try XCTUnwrap(model.summonWatchdogTokenForTesting)
        XCTAssertEqual(model.pendingSummonSource, "omakase")
        XCTAssertNotEqual(staleToken, currentToken)

        // A's late send-throw lands NOW. It must no-op: B's slot and token are
        // untouched, and no "ask"-sourced error marker is appended.
        model.invokeSummonSendFailureForTesting(
            token: staleToken, source: "ask", error: SummonTestError.deadSocket)

        XCTAssertTrue(model.isSummonBusy, "the newer summon's slot must still be held")
        XCTAssertEqual(model.pendingSummonSource, "omakase",
                       "a superseded send-failure must not release a newer summon's slot")
        XCTAssertEqual(model.summonWatchdogTokenForTesting, currentToken,
                       "the newer summon's watchdog token must be intact")
        XCTAssertEqual(
            model.summonResults.filter { $0.source == "ask" && $0.text.contains("Error:") }.count, 0,
            "no error marker for the superseded summon (its normal reply may remain)")
    }

    /// Positive case: when the failing send STILL owns the slot (token+source
    /// match), its cleanup releases the slot and surfaces the bounded error.
    func testCurrentSummonSendFailureClearsSlotAndAppendsError() async throws {
        PetModel.summonReplyTimeoutSeconds = 5.0

        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        model.claimSharedSummonForTesting(source: "ask")
        let token = try XCTUnwrap(model.summonWatchdogTokenForTesting)
        XCTAssertTrue(model.isSummonBusy)

        model.invokeSummonSendFailureForTesting(
            token: token, source: "ask", error: SummonTestError.deadSocket)

        XCTAssertFalse(model.isSummonBusy, "the owning send-failure clears the slot")
        XCTAssertNil(model.summonWatchdogTokenForTesting,
                     "the owning send-failure nils the watchdog token")
        let askEntries = model.summonResults.filter { $0.source == "ask" }
        XCTAssertEqual(askEntries.count, 1, "exactly one error marker for the owning summon")
        XCTAssertTrue(askEntries.first?.text.contains("Error:") ?? false,
                      "the surfaced marker carries the error text")
    }
}
