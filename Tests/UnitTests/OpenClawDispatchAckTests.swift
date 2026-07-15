import XCTest
@testable import ClawGate

final class OpenClawDispatchAckTests: XCTestCase {
    private var originalLogStoreDir: String = ""

    override func setUp() {
        super.setUp()
        PetLogStore.testIsolationSemaphore.wait()
        originalLogStoreDir = PetLogStore.dir
        PetLogStore.dir = NSTemporaryDirectory() + "clawgate-openclaw-dispatch-tests-" + UUID().uuidString
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: PetLogStore.dir)
        PetLogStore.dir = originalLogStoreDir
        PetLogStore.testIsolationSemaphore.signal()
        super.tearDown()
    }

    private func decodeIncomingPayload(_ json: String) throws -> IncomingPayload {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(IncomingPayload.self, from: data)
    }

    private func buildDecision() -> PetLogContextDecision {
        PetLogContextDecision(
            policyVersion: PetLogPromptBuilder.policyVersion,
            includedSegmentIds: ["segment-1"],
            includedRange: PetLogSegmentRange(startSegmentId: "segment-1", endSegmentId: "segment-1"),
            excludedAdjacentRange: nil,
            boundaryReasonCodes: ["manual"],
            boundaryConfidence: .high,
            historyComplete: true,
            correctionCounts: [:]
        )
    }

    private func structuredLogReplyJSON(answer: String, segmentId: String) -> String {
        let escaped = String(data: try! JSONEncoder().encode(answer), encoding: .utf8)!
        return """
        {
          "answer": \(escaped),
          "contextDecision": {
            "policyVersion": "\(PetLogPromptBuilder.policyVersion)",
            "includedSegmentIds": ["\(segmentId)"],
            "includedRange": {
              "startSegmentId": "\(segmentId)",
              "endSegmentId": "\(segmentId)"
            },
            "excludedAdjacentRange": {"startSegmentId": null, "endSegmentId": null},
            "boundaryReasonCodes": [],
            "boundaryConfidence": "high",
            "historyComplete": true,
            "correctionCounts": {}
          }
        }
        """
    }

    private func makeValidTerraAck() -> PetLogDispatchAck {
        PetLogDispatchAck(
            runId: "run-terra",
            resolvedModel: "openai/gpt-5.6-terra",
            resolvedThinking: "max",
            degraded: true,
            fallbackReason: "rate_limited"
        )
    }

    func testChatSendParamsEncodesOnlyCanonicalLogSendKeys() throws {
        let params = ChatSendParams(sessionKey: "session", message: "ping", idempotencyKey: "id")
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let keys = decoded.flatMap { Set($0.keys) } ?? Set<String>()

        XCTAssertEqual(keys, Set(["sessionKey", "message", "idempotencyKey"]))
        XCTAssertNil(decoded?["model"])
        XCTAssertNil(decoded?["thinking"])
        XCTAssertNil(decoded?["policyVersion"])
    }

    /// 2026-07-16 live E2E incident: the Gateway ACK came back
    /// `resolvedThinking: "medium"` because the outbound chat.send never
    /// carried `model`/`thinking` — a bare prefix marker in the message text
    /// was not sufficient for the Gateway to route to Sol/max. This is the
    /// exact-key/canonical-value regression guard for the fix.
    func testPetLogChatSendParamsEncodesExactFiveKeysWithCanonicalModelAndThinking() throws {
        let params = PetLogChatSendParams(sessionKey: "session", message: "ping", idempotencyKey: "id")
        let data = try JSONEncoder().encode(params)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])

        XCTAssertEqual(Set(decoded.keys), Set(["sessionKey", "message", "idempotencyKey", "model", "thinking"]))
        XCTAssertEqual(decoded["model"] as? String, "openai/gpt-5.6-sol")
        XCTAssertEqual(decoded["thinking"] as? String, "max")
        XCTAssertEqual(decoded["sessionKey"] as? String, "session")
        XCTAssertEqual(decoded["message"] as? String, "ping")
        XCTAssertEqual(decoded["idempotencyKey"] as? String, "id")
    }

    /// Static guard against the exact failure class this task fixes: an ACK
    /// validator can be perfectly correct while the actual outbound request
    /// never carries the fields the ACK is being validated against — this
    /// asserts `sendMessageAwaitingPetLogDispatchAck`'s own source actually
    /// constructs a `PetLogChatSendParams`, not a bare `ChatSendParams`, and
    /// that every OTHER chat.send call site is unaffected.
    func testSendMessageAwaitingPetLogDispatchAckWiresPetLogChatSendParams() throws {
        let path = "\(sourceRoot())/ClawGate/Core/OpenClaw/OpenClawWSClient.swift"
        let source = try String(contentsOfFile: path, encoding: .utf8)
        guard let funcRange = source.range(of: "func sendMessageAwaitingPetLogDispatchAck"),
              let funcEndRange = source.range(of: "\n    }", range: funcRange.upperBound..<source.endIndex) else {
            XCTFail("could not locate sendMessageAwaitingPetLogDispatchAck in source")
            return
        }
        let body = source[funcRange.upperBound..<funcEndRange.lowerBound]
        XCTAssertTrue(body.contains("PetLogChatSendParams("),
                       "sendMessageAwaitingPetLogDispatchAck must construct PetLogChatSendParams, not a bare ChatSendParams")

        XCTAssertTrue(source.contains("func sendMessage(_ text: String, sessionKey: String) async throws {\n        let requestId = UUID().uuidString\n        let request = GatewayRequest(\n            type: \"req\", id: requestId, method: \"chat.send\",\n            params: ChatSendParams("),
                       "ordinary sendMessage must keep using plain ChatSendParams (3 keys), unchanged")
    }

    private func sourceRoot() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    func testValidNormalSolDispatchAckPassesValidation() throws {
        let payload = try decodeIncomingPayload("""
        {
          "runId": "run-1",
          "resolvedModel": "openai/gpt-5.6-sol",
          "resolvedThinking": "max",
          "degraded": false,
          "fallbackReason": null
        }
        """)

        let ack = try PetLogDispatchAck.validate(from: payload)
        XCTAssertEqual(ack.runId, "run-1")
        XCTAssertEqual(ack.resolvedModel, "openai/gpt-5.6-sol")
        XCTAssertEqual(ack.resolvedThinking, "max")
        XCTAssertEqual(ack.degraded, false)
        XCTAssertNil(ack.fallbackReason)
    }

    func testValidTerraDispatchAckPassesValidation() throws {
        let payload = try decodeIncomingPayload("""
        {
          "runId": "run-2",
          "resolvedModel": "openai/gpt-5.6-terra",
          "resolvedThinking": "max",
          "degraded": true,
          "fallbackReason": "rate_limited"
        }
        """)

        let ack = try PetLogDispatchAck.validate(from: payload)
        XCTAssertEqual(ack.runId, "run-2")
        XCTAssertEqual(ack.resolvedModel, "openai/gpt-5.6-terra")
        XCTAssertEqual(ack.resolvedThinking, "max")
        XCTAssertEqual(ack.degraded, true)
        XCTAssertEqual(ack.fallbackReason, "rate_limited")
    }

    func testInvalidDispatchAckRejectsMissingRequiredFields() throws {
        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "resolvedModel": "openai/gpt-5.6-sol",
              "resolvedThinking": "max",
              "degraded": false,
              "fallbackReason": null
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-1",
              "resolvedModel": "openai/gpt-5.6-sol",
              "fallbackReason": null
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-1",
              "resolvedModel": "openai/gpt-5.6-sol",
              "degraded": false,
              "fallbackReason": null
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-1",
              "resolvedModel": "openai/gpt-5.6-sol",
              "resolvedThinking": "max",
              "degraded": true
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-1",
              "resolvedModel": "openai/gpt-5.6-sol",
              "resolvedThinking": "max",
              "degraded": true,
              "fallbackReason": "rate_limited"
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-1",
              "resolvedModel": "openai/gpt-5.6-terra",
              "resolvedThinking": "max",
              "degraded": false,
              "fallbackReason": "rate_limited"
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-1",
              "resolvedModel": "openai/gpt-5.6-terra",
              "resolvedThinking": "max",
              "degraded": true
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "   ",
              "resolvedModel": "openai/gpt-5.6-sol",
              "resolvedThinking": "max",
              "degraded": false,
              "fallbackReason": null
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-1",
              "resolvedModel": "",
              "resolvedThinking": "max",
              "degraded": false,
              "fallbackReason": null
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())
    }

    func testInvalidDispatchAckRejectsWrongThinkingOrModel() throws {
        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-1",
              "resolvedModel": "openai/gpt-5.6-sol",
              "resolvedThinking": "fast",
              "degraded": false,
              "fallbackReason": null
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-2",
              "resolvedModel": "openai/gpt-5.6-flash",
              "resolvedThinking": "max",
              "degraded": false,
              "fallbackReason": null
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())
    }

    func testInvalidDispatchAckRejectsTerraFallbackFormatOrRange() throws {
        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-3",
              "resolvedModel": "openai/gpt-5.6-terra",
              "resolvedThinking": "max",
              "degraded": true,
              "fallbackReason": null
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-4",
              "resolvedModel": "openai/gpt-5.6-terra",
              "resolvedThinking": "max",
              "degraded": true,
              "fallbackReason": "bad/reason"
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())

        let longReason = String(repeating: "a", count: 129)
        XCTAssertThrowsError(try {
            let payload = try decodeIncomingPayload("""
            {
              "runId": "run-5",
              "resolvedModel": "openai/gpt-5.6-terra",
              "resolvedThinking": "max",
              "degraded": true,
              "fallbackReason": "\(longReason)"
            }
            """)
            _ = try PetLogDispatchAck.validate(from: payload)
        }())
    }

    func testPetLogEntryMetadataRoundTripsWithDispatchAndBackwardsCompat() throws {
        let dispatch = PetLogDispatchMetadata(
            runId: "run-1",
            resolvedModel: "openai/gpt-5.6-terra",
            resolvedThinking: "max",
            degraded: true,
            fallbackReason: "rate_limited"
        )
        let decision = buildDecision()
        let metadata = PetLogEntryMetadata(contextDecision: decision, completeBeforeAnchor: false, dispatch: dispatch)
        let entry = NotificationEntry(
            id: "entry-1",
            text: "answer",
            source: "log",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            logMetadata: metadata
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(NotificationEntry.self, from: data)

        XCTAssertEqual(decoded.logMetadata?.dispatch, dispatch)

        let legacyMetadataJSON = """
        {
          "id": "old",
          "text": "legacy",
          "source": "log",
          "timestamp": 700000000,
          "logMetadata": {
            "contextDecision": {
              "policyVersion": "\(PetLogPromptBuilder.policyVersion)",
              "includedSegmentIds": [],
              "includedRange": null,
              "excludedAdjacentRange": null,
              "boundaryReasonCodes": [],
              "boundaryConfidence": "low",
              "historyComplete": false,
              "correctionCounts": {}
            },
            "completeBeforeAnchor": false
          }
        }
        """
        let legacy = try JSONDecoder().decode(NotificationEntry.self, from: Data(legacyMetadataJSON.utf8))
        XCTAssertNil(legacy.logMetadata?.dispatch)
    }

    func testStructuredLogAppendPersistsPetLogDispatchMetadata() {
        let model = PetModel()
        let ack = makeValidTerraAck()
        let metadata = PetLogDispatchMetadata(
            runId: ack.runId,
            resolvedModel: ack.resolvedModel,
            resolvedThinking: ack.resolvedThinking,
            degraded: ack.degraded,
            fallbackReason: ack.fallbackReason
        )
        model.setPendingLogRequestForTesting(segmentIds: ["segment-1"], completeBeforeAnchor: true, dispatch: ack)
        model.addSummonResult(text: structuredLogReplyJSON(answer: "hello", segmentId: "segment-1"), source: "log", parseAsStructured: true)

        let entries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.logMetadata?.dispatch, metadata)
        XCTAssertEqual(entries.first?.logMetadata?.dispatch?.degraded, true)
    }

    func testPetLogThreadTranscriptMarksTerraFallbackOnlyForDegradedDispatch() {
        let normal = NotificationEntry(
            id: "n1",
            text: "normal",
            source: "log",
            timestamp: Date(),
            logMetadata: PetLogEntryMetadata(
                contextDecision: buildDecision(),
                completeBeforeAnchor: true,
                dispatch: PetLogDispatchMetadata(
                    runId: "run-a",
                    resolvedModel: "openai/gpt-5.6-sol",
                    resolvedThinking: "max",
                    degraded: false,
                    fallbackReason: nil
                )
            )
        )
        let degraded = NotificationEntry(
            id: "d1",
            text: "fallback",
            source: "log",
            timestamp: Date(),
            logMetadata: PetLogEntryMetadata(
                contextDecision: buildDecision(),
                completeBeforeAnchor: true,
                dispatch: PetLogDispatchMetadata(
                    runId: "run-b",
                    resolvedModel: "openai/gpt-5.6-terra",
                    resolvedThinking: "max",
                    degraded: true,
                    fallbackReason: "rate_limited"
                )
            )
        )

        let normalText = AmbientLogPetView.nsAttributedThreadTranscript([normal]).string
        let degradedText = AmbientLogPetView.nsAttributedThreadTranscript([degraded]).string

        XCTAssertFalse(normalText.contains("⚠ Solを利用できずTerraで処理しました"))
        XCTAssertTrue(degradedText.contains("⚠ Solを利用できずTerraで処理しました"))
    }
}
