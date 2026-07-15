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
        // A structured "log" reply is only parsed when there is a pending
        // request to validate it against (fail-closed contract). Establish the
        // one a real in-flight Log summon would have left behind.
        model.setPendingLogRequestForTesting(segmentIds: [], completeBeforeAnchor: true)

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
            "includedRange": null,
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
        // Reach the connected path (arm the watchdog + claim the summon slot),
        // but suppress the real WS send so the reply-timeout watchdog is the
        // sole release mechanism — deterministically reproducing "send
        // succeeded, reply never arrived" without a socket racing the watchdog.
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true
        let envelope = PetLogQueryEnvelope(
            requestId: UUID().uuidString, actionId: "slot-0", instruction: "質問まとめ",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true, segments: []
        )
        model.sendLogInstruction(envelope: envelope)
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
        // Drive the reply path directly (a disconnected sendLogInstruction now
        // fails fast without arming this path — that is covered separately).
        model.pendingSummonSource = "log"
        model.pendingSummonRunId = nil
        // A pending request exists (this exercises the PARSE-failure path, not
        // the no-pending-request path covered separately below).
        model.setPendingLogRequestForTesting(segmentIds: [], completeBeforeAnchor: true)

        model.addSummonResult(text: "not valid json at all", source: "log", parseAsStructured: true)

        let logEntries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(logEntries.count, 1)
        XCTAssertTrue(logEntries.first?.text.contains("did not match") ?? false,
                      "must surface the fail-closed marker, not the raw garbled reply")
        XCTAssertNil(logEntries.first?.logMetadata,
                     "a parse failure must not carry fabricated model metadata")
    }

    /// A structured "log" reply that arrives with NO pending request to
    /// validate against must fail closed WITHOUT parsing — never fabricating an
    /// empty allowed-id set or a default completeness signal that would let a
    /// vacuously-valid reply (empty included + null range) get persisted with a
    /// made-up `completeBeforeAnchor`.
    func testStructuredReplyWithNoPendingRequestFailsClosed() {
        let model = PetModel()
        // Enter the "log" reply path but never establish a pending request
        // (i.e. sendLogInstruction was never called for this reply).
        model.pendingSummonSource = "log"
        model.pendingSummonRunId = nil

        let wellFormed = Self.structuredLogReplyJSON(answer: "fabricated answer text")
        model.addSummonResult(text: wellFormed, source: "log", parseAsStructured: true)

        let logEntries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(logEntries.count, 1)
        XCTAssertNil(logEntries.first?.logMetadata,
                     "no pending request must not yield fabricated metadata")
        XCTAssertNotEqual(logEntries.first?.text, "fabricated answer text",
                          "the reply must not be parsed/shown when there is nothing to validate it against")
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

    /// Static guard: message/instruction/answer bodies must never be written
    /// to NSLog. NSLog output isn't interceptable in a unit test, so this scans
    /// the source for the content-bearing log patterns that were removed and
    /// asserts they are not reintroduced. Mirrors the source-scan pattern used
    /// by AmbientLogModelThreadTranscriptTests.
    func testNoMessageBodyIsLoggedToNSLog() throws {
        let root = sourceRoot()
        let petModel = try String(
            contentsOfFile: "\(root)/ClawGate/UI/Pet/PetModel.swift", encoding: .utf8)
        XCTAssertFalse(petModel.contains("msg.text.prefix"),
                       "message-body prefixes must not be passed to NSLog")
        XCTAssertFalse(petModel.contains("bubble_notify received: %@"),
                       "bubble_notify must not log the message body")

        let wsClient = try String(
            contentsOfFile: "\(root)/ClawGate/Core/OpenClaw/OpenClawWSClient.swift", encoding: .utf8)
        XCTAssertFalse(wsClient.contains("data.prefix(200)"),
                       "decode-failure log must not include raw body bytes")
    }

    private func sourceRoot() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    private func logEnvelope() -> PetLogQueryEnvelope {
        PetLogQueryEnvelope(
            requestId: UUID().uuidString, actionId: "slot-0", instruction: "質問まとめ",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true, segments: []
        )
    }

    /// A Log action fired while disconnected must surface a bounded, immediate,
    /// visible error — NOT a saved `log_user` prompt plus a fake multi-second
    /// watchdog wait before any error appears.
    func testDisconnectedLogInstructionSurfacesImmediateErrorWithoutLogUserOrWatchdog() async throws {
        let model = PetModel()  // fresh: no sessionKey, not busy

        model.sendLogInstruction(envelope: logEnvelope())

        // The error is present synchronously, with no summon slot claimed and
        // no awaiting-reply state entered.
        let logEntries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(logEntries.count, 1, "exactly one bounded error entry")
        XCTAssertTrue(logEntries.first?.text.contains("not connected") ?? false)
        XCTAssertFalse(model.logReplies.contains { $0.source == "log_user" },
                       "no log_user prompt may be saved when the send can't happen")
        XCTAssertNil(logEntries.first?.logMetadata)
        XCTAssertFalse(model.isSummonBusy)
        XCTAssertFalse(model.logAwaitingReply)

        // No watchdog was armed, so nothing fires to add a second entry.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.logReplies.filter { $0.source == "log" }.count, 1,
                       "no delayed watchdog entry may appear")
    }

    /// A Log action fired while another Chi summon (here scene naming) is in
    /// flight must not stomp it: no overwrite of pendingSummonSource, no
    /// log_user prompt — just a bounded, visible busy marker.
    func testBusyLogInstructionDoesNotStompInFlightSummon() {
        let model = PetModel()
        // Simulate an in-flight scene-naming summon.
        model.pendingSummonSource = "log_scene_naming"

        model.sendLogInstruction(envelope: logEnvelope())

        XCTAssertEqual(model.pendingSummonSource, "log_scene_naming",
                       "an in-flight summon must not be overwritten to \"log\"")
        let logEntries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(logEntries.count, 1, "exactly one bounded busy-error entry")
        XCTAssertTrue(logEntries.first?.text.contains("busy") ?? false)
        XCTAssertFalse(model.logReplies.contains { $0.source == "log_user" },
                       "no log_user prompt may be saved when refused for busy")
    }
}
