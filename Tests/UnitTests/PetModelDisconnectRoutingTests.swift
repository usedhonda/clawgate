import XCTest
@testable import ClawGate

/// Reproduces the 2026-07-13 18:42 JST incident: a "質問まとめ" (Log summarize)
/// request completed successfully server-side (task_complete + WS final sent),
/// but the reply never reached the Log pane. Root cause: the WS client's
/// ping-timeout reconnect churn tore down the connection mid-stream; the
/// client's 5s delta-idle timer then finalized the in-flight reply with only
/// the partial text accumulated so far, clearing `pendingSummonSource` before
/// the real final could arrive. The real final then fell through to the
/// generic chat path instead of the Log pane.
final class PetModelDisconnectRoutingTests: XCTestCase {
    private var originalIdleTimeoutNanos: UInt64 = 0
    private var originalLogAwaitingReplyTimeoutSeconds: TimeInterval = 0
    private var originalLogStoreDir = ""

    override func setUp() {
        super.setUp()
        originalIdleTimeoutNanos = PetModel.deltaIdleTimeoutNanos
        PetModel.deltaIdleTimeoutNanos = 80_000_000 // 80ms, shrunk for fast/deterministic tests
        originalLogAwaitingReplyTimeoutSeconds = PetModel.logAwaitingReplyTimeoutSeconds
        PetModel.logAwaitingReplyTimeoutSeconds = 0.1 // 100ms, shrunk for fast/deterministic tests

        // A bare PetModel() starts with empty in-memory logReplies (real disk
        // load only happens in start(), which this test never calls). If a
        // "log"-source completion below reaches PetLogStore.save(), it must
        // never write through to the user's real ~/.clawgate/logs/log.json —
        // redirect to a throwaway temp directory for the duration of the test.
        // `dir` is a process-global static: hold the shared semaphore for the
        // entire setUp...tearDown lifetime so a parallel test in another
        // class can't race this override.
        PetLogStore.testIsolationSemaphore.wait()
        originalLogStoreDir = PetLogStore.dir
        PetLogStore.dir = NSTemporaryDirectory() + "clawgate-test-logs-\(UUID().uuidString)"
    }

    override func tearDown() {
        PetModel.deltaIdleTimeoutNanos = originalIdleTimeoutNanos
        PetModel.logAwaitingReplyTimeoutSeconds = originalLogAwaitingReplyTimeoutSeconds
        try? FileManager.default.removeItem(atPath: PetLogStore.dir)
        PetLogStore.dir = originalLogStoreDir
        PetLogStore.testIsolationSemaphore.signal()
        super.tearDown()
    }

    func testDisconnectMidStreamDoesNotTruncateOrDropPendingLogReply() async throws {
        let model = PetModel()
        model.pendingSummonSource = "log"

        // Two deltas for the same messageId: the first starts the stream, the
        // second is what actually (re)schedules the delta-idle finalize timer.
        model.handleEvent(.delta(messageId: "m1", text: "partial fragment"))
        model.handleEvent(.delta(messageId: "m1", text: " / 狙い:"))
        model.handleEvent(.disconnected(reason: "ping timeout"))

        // Let the (shortened) delta-idle window fully elapse — proves the
        // idle timer does not fire and truncate the pending reply.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Reconnect + resubscribe delivers the real, complete final. Under
        // Phase A a "log" final is the structured JSON envelope, whose parsed
        // `answer` is what reaches the pane.
        let fullMessage = OpenClawChatMessage(
            role: .assistant, text: Self.structuredLogReplyJSON(answer: "complete answer text"))
        model.handleEvent(.message(fullMessage))
        try await Task.sleep(nanoseconds: 50_000_000)

        let logEntries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(logEntries.count, 1, "exactly one log reply should be recorded")
        XCTAssertEqual(logEntries.first?.text, "complete answer text",
                        "the full final text must reach the Log pane, not a mid-stream fragment")
        XCTAssertTrue(model.messages.isEmpty,
                       "the final must not fall through to the plain chat pane")
    }

    /// A minimal well-formed structured Log reply whose parsed `answer` is
    /// `answer` — the wire shape a real "log" final now carries under Phase A.
    static func structuredLogReplyJSON(answer: String) -> String {
        let escaped = String(data: try! JSONEncoder().encode(answer), encoding: .utf8)!
        return """
        {
          "answer": \(escaped),
          "contextDecision": {
            "policyVersion": "\(PetLogPromptBuilder.policyVersion)",
            "includedSegmentIds": [],
            "includedRange": {"startSegmentId": null, "endSegmentId": null},
            "excludedAdjacentRange": {"startSegmentId": null, "endSegmentId": null},
            "boundaryReasonCodes": [],
            "boundaryConfidence": "high",
            "historyComplete": true,
            "correctionCounts": {}
          }
        }
        """
    }

    /// 2026-07-15 16:58 JST incident: the WS connection was stuck in a
    /// sustained ping-timeout/reconnect loop (OpenClawWSClient.handlePingTimeout)
    /// for 20+ minutes. Reconnect + resubscribe never replays events missed
    /// while the connection was down, so a "質問まとめ" reply emitted during a
    /// down window is lost permanently — no terminal WS event ever arrives to
    /// clear `pendingSummonSource`. Before this fix that left the summon slot
    /// wedged forever with no visible sign anything had gone wrong.
    func testLogAwaitingReplyTimeoutReleasesStuckSummonSlotWithVisibleMarker() async throws {
        let model = PetModel()
        let envelope = PetLogQueryEnvelope(
            requestId: UUID().uuidString, actionId: "slot-0", instruction: "質問まとめ",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true, segments: []
        )
        model.sendLogInstruction(envelope: envelope)
        // sendSummon only sets pendingSummonSource once a real sessionKey
        // exists; simulate the in-flight state a connected session would have.
        model.pendingSummonSource = "log"
        XCTAssertTrue(model.logAwaitingReply)
        XCTAssertTrue(model.isSummonBusy)

        // No terminal WS event (message/messageComplete/idle-finalize) ever
        // arrives — let the (shortened) awaiting-reply watchdog fire.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(model.logAwaitingReply, "the awaiting-reply flag must clear")
        XCTAssertFalse(model.isSummonBusy, "pendingSummonSource must not stay wedged forever")
        let logEntries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(logEntries.count, 1,
                        "a visible marker must be recorded so the user isn't left with silent nothing")
        XCTAssertTrue(logEntries.first?.text.contains("no reply received") ?? false)
    }

    /// A late event from a DIFFERENT run must be dropped without touching any
    /// pending-summon state (source/runId/isStreaming/streamingText). This is
    /// the state-corruption regression: a run-B mismatch must not wipe the
    /// run-A stream that is still in flight.
    func testMismatchedRunEventDoesNotCorruptInFlightLogSummon() async throws {
        let model = PetModel()
        model.pendingSummonSource = "log"
        model.pendingSummonRunId = "run-A"

        // Real partial from OUR run accumulates into the stream. A single delta
        // starts the stream without arming the delta-idle finalize timer (only
        // a same-id follow-up delta does), so nothing here finalizes on its own.
        model.handleEvent(.delta(messageId: "run-A", text: "partial real answer"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.streamingText, "partial real answer")
        XCTAssertTrue(model.isStreaming)

        // A final from a DIFFERENT run arrives — it must be dropped, leaving
        // every piece of pending state untouched.
        model.handleEvent(.message(OpenClawChatMessage(id: "run-B", role: .assistant, text: "wrong run")))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.pendingSummonSource, "log", "mismatched run must not clear the summon slot")
        XCTAssertEqual(model.pendingSummonRunId, "run-A", "mismatched run must not overwrite the tracked runId")
        XCTAssertEqual(model.streamingText, "partial real answer",
                       "mismatched run must not wipe the in-flight accumulated text")
        XCTAssertTrue(model.isStreaming, "mismatched run must not clear isStreaming")
        XCTAssertEqual(model.logReplies.filter { $0.source == "log" }.count, 0,
                       "no log reply may be recorded from a mismatched run")
    }

    /// A model reply that does not parse as the expected structured JSON must
    /// fail closed: a visible error marker, never the raw garbled text, and
    /// with no fabricated metadata.
    func testStructuredParseFailsClosedOnNonJSONReply() {
        let model = PetModel()
        let envelope = PetLogQueryEnvelope(
            requestId: UUID().uuidString, actionId: "free", instruction: "まとめて",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true, segments: []
        )
        model.sendLogInstruction(envelope: envelope)
        model.pendingSummonSource = "log"
        model.pendingSummonRunId = nil

        model.addSummonResult(text: "not valid json at all", source: "log", parseAsStructured: true)

        let logEntries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(logEntries.count, 1)
        XCTAssertTrue(logEntries.first?.text.contains("did not match") ?? false,
                      "must surface the fail-closed marker, not the raw garbled reply")
        XCTAssertNil(logEntries.first?.logMetadata,
                     "a parse failure must not carry fabricated model metadata")
    }

    /// `logMetadata` round-trips through Codable, and an old log.json entry
    /// with no `logMetadata` key still decodes (backward-compatible).
    func testNotificationEntryLogMetadataCodableRoundTripAndBackwardCompat() throws {
        let decision = PetLogContextDecision(
            policyVersion: PetLogPromptBuilder.policyVersion,
            includedSegmentIds: ["a", "b"],
            includedRange: PetLogSegmentRange(startSegmentId: "a", endSegmentId: "b"),
            excludedAdjacentRange: nil,
            boundaryReasonCodes: ["scene-continuous"],
            boundaryConfidence: .low,
            historyComplete: false,
            correctionCounts: ["proper-noun": 1]
        )
        let entry = NotificationEntry(
            id: "e1", text: "answer", source: "log", timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            logMetadata: PetLogEntryMetadata(contextDecision: decision, completeBeforeAnchor: false)
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(NotificationEntry.self, from: data)
        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.text, entry.text)
        XCTAssertEqual(decoded.source, entry.source)
        XCTAssertEqual(decoded.logMetadata, entry.logMetadata, "metadata must survive an encode/decode round-trip")
        XCTAssertEqual(decoded.logMetadata?.isUncertain, true)

        // An entry written before Phase A has no `logMetadata` key at all.
        let legacyJSON = """
        {"id":"old1","text":"legacy answer","source":"log","timestamp":700000000}
        """
        let legacy = try JSONDecoder().decode(NotificationEntry.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.logMetadata, "old entries without the key must decode with logMetadata == nil")
        XCTAssertEqual(legacy.text, "legacy answer")
    }
}
