import XCTest
import CryptoKit
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
          "outcome": "answer",
          "answer": \(escaped),
          "contextDecision": {
            "policyVersion": "\(PetLogPromptBuilder.policyVersion)",
            "includedSegmentIds": ["\(segmentId)"],
            "includedRange": {
              "startSegmentId": "\(segmentId)",
              "endSegmentId": "\(segmentId)"
            },
            "excludedAdjacentRange": null,
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
            sessionKey: "agent:main:main",
            resolvedModel: "openai/gpt-5.6-terra",
            resolvedThinking: "max",
            degraded: true,
            fallbackReason: "rate_limited",
            isolationApplied: true,
            nonprojectionApplied: true
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
    func testPetLogChatSendParamsEncodesExactEightKeysWithRequestLocalDelivery() throws {
        let params = PetLogChatSendParams(sessionKey: "session", message: "ping", idempotencyKey: "id")
        let data = try JSONEncoder().encode(params)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])

        XCTAssertEqual(Set(decoded.keys), Set([
            "sessionKey", "message", "idempotencyKey", "model", "thinking",
            "requestLocalContext", "nonprojection", "retainTerminalResult"
        ]))
        XCTAssertEqual(decoded["model"] as? String, "openai/gpt-5.6-sol")
        XCTAssertEqual(decoded["thinking"] as? String, "max")
        XCTAssertEqual(decoded["sessionKey"] as? String, "session")
        XCTAssertEqual(decoded["message"] as? String, "ping")
        XCTAssertEqual(decoded["idempotencyKey"] as? String, "id")
        XCTAssertEqual(decoded["requestLocalContext"] as? Bool, true)
        XCTAssertEqual(decoded["nonprojection"] as? Bool, true)
        XCTAssertEqual(decoded["retainTerminalResult"] as? Bool, true)
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

    private func waitForMainQueue(_ hops: Int = 1) async {
        guard hops > 0 else { return }
        for _ in 0..<hops {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }

    private func persistedJsonHashes() -> [String: String?] {
        let watchedFiles = [
            "summon.json",
            "log.json",
            "notifications.json",
            "local.json",
            "recovery-warnings.json"
        ]

        return Dictionary(uniqueKeysWithValues: watchedFiles.map { file in
            let path = (PetLogStore.dir as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                return (file, nil)
            }
            let digest = SHA256.hash(data: data)
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            return (file, hash)
        })
    }

    private func assertNonSummonPersistenceUnchanged(before: [String: String?], after: [String: String?]) {
        let ignoreSet = ["summon.json"]
        let candidates = before.keys.filter { !ignoreSet.contains($0) }
        for filename in candidates {
            XCTAssertEqual(before[filename], after[filename], "\(filename) changed")
        }
    }

    private func routeIncomingEvents(_ eventName: String, payloadJSON: String) throws -> [OpenClawEvent] {
        let payload = try decodeIncomingPayload(payloadJSON)
        return OpenClawWSClient.routeIncomingEvent(name: eventName, payload: payload)
    }

    func testEventOwnerIdentityPreservesRunIdAndSessionKeyWithoutCollapsingByRunId() throws {
        let sameRunPrimary = OpenClawEventOwnerIdentity(runId: "run-1", sessionKey: "agent:main:main")
        let sameRunProactive = OpenClawEventOwnerIdentity(runId: "run-1", sessionKey: "agent:main:proactive:heartbeat")

        XCTAssertNotEqual(sameRunPrimary, sameRunProactive)
        XCTAssertEqual(sameRunPrimary.runId, sameRunProactive.runId)
        XCTAssertNotEqual(sameRunPrimary.sessionKey, sameRunProactive.sessionKey)
        XCTAssertNotEqual(sameRunPrimary.completeOwnerKey, sameRunProactive.completeOwnerKey)
        XCTAssertEqual(sameRunPrimary.completeOwnerKey?.sessionKey, "agent:main:main")
        XCTAssertEqual(sameRunPrimary.completeOwnerKey?.runId, "run-1")
        XCTAssertEqual(sameRunProactive.completeOwnerKey?.sessionKey, "agent:main:proactive:heartbeat")
        XCTAssertEqual(sameRunPrimary.messageId, "run-1")
        XCTAssertTrue(sameRunPrimary.hasCompleteOwnerKey)

        let canonicalDelta = OpenClawEvent.delta(messageId: sameRunPrimary, text: "typing")
        guard case .delta(let owner, _) = canonicalDelta else {
            XCTFail("delta event should carry owner identity")
            return
        }
        XCTAssertEqual(owner.runId, "run-1")
        XCTAssertEqual(owner.sessionKey, "agent:main:main")
        XCTAssertTrue(owner.hasSessionKey)

        let incomplete = OpenClawEvent.delta(messageId: OpenClawEventOwnerIdentity(runId: "run-1"), text: "typing")
        guard case .delta(let incompleteOwner, _) = incomplete else {
            XCTFail("incomplete delta should still carry identity")
            return
        }
        XCTAssertNil(incompleteOwner.sessionKey)
        XCTAssertFalse(incompleteOwner.hasCompleteOwnerKey)
    }

    func testCanonicalChatFinalEventPreservesRunIdSessionAndCompleteOwner() throws {
        let payloadJSON = """
        {
          "type": "chat",
          "state": "final",
          "runId": "run-1",
          "sessionKey": "agent:main:main",
          "message": {
            "role": "assistant",
            "content": [
              { "type": "text", "text": "hello" }
            ]
          }
        }
        """
        let events = try routeIncomingEvents("chat", payloadJSON: payloadJSON)
        let event = try XCTUnwrap(events.first)
        guard case .message(let msg) = event else {
            XCTFail("chat final should map to .message")
            return
        }
        XCTAssertEqual(msg.id, "run-1")
        XCTAssertEqual(msg.owner?.messageId, "run-1")
        XCTAssertEqual(msg.owner?.runId, "run-1")
        XCTAssertEqual(msg.owner?.sessionKey, "agent:main:main")
        XCTAssertEqual(msg.owner?.completeOwnerKey?.sessionKey, "agent:main:main")
        XCTAssertEqual(msg.owner?.completeOwnerKey?.runId, "run-1")
    }

    func testCanonicalProactiveChatFinalKeepsProactiveFlag() throws {
        let payloadJSON = """
        {
          "type": "chat",
          "state": "final",
          "runId": "run-1",
          "sessionKey": "agent:main:proactive:heartbeat",
          "message": {
            "role": "assistant",
            "content": [{ "type": "text", "text": "proactive hello" }]
          }
        }
        """
        let events = try routeIncomingEvents("chat", payloadJSON: payloadJSON)
        let event = try XCTUnwrap(events.first)
        guard case .message(let msg) = event else {
            XCTFail("chat final should map to .message")
            return
        }
        XCTAssertTrue(msg.isProactive)
        XCTAssertEqual(msg.owner?.sessionKey, "agent:main:proactive:heartbeat")
    }

    func testCanonicalAgentDeltaPreservesWireRunIdAndSessionKey() throws {
        let events = try routeIncomingEvents("agent", payloadJSON: """
        {
          "type": "agent",
          "stream": "assistant",
          "runId": "run-1",
          "sessionKey": "agent:main:main",
          "data": {
            "delta": "typing"
          }
        }
        """)
        let event = try XCTUnwrap(events.first)
        guard case .delta(let owner, let delta) = event else {
            XCTFail("agent event should map to .delta")
            return
        }
        XCTAssertEqual(owner.messageId, "run-1")
        XCTAssertEqual(owner.runId, "run-1")
        XCTAssertEqual(owner.sessionKey, "agent:main:main")
        XCTAssertEqual(owner.completeOwnerKey?.sessionKey, "agent:main:main")
        XCTAssertEqual(owner.completeOwnerKey?.runId, "run-1")
        XCTAssertEqual(delta, "typing")
    }

    func testAssistantLegacyDeltaAndCompleteStayIncompleteWithoutRunId() throws {
        let deltaEvents = try routeIncomingEvents("assistant.delta", payloadJSON: """
        {
          "type": "assistant.delta",
          "messageId": "message-id-1",
          "delta": "typing"
        }
        """)
        let deltaEvent = try XCTUnwrap(deltaEvents.first)
        guard case .delta(let owner, let deltaText) = deltaEvent else {
            XCTFail("assistant.delta should map to .delta")
            return
        }
        XCTAssertEqual(owner.messageId, "message-id-1")
        XCTAssertNil(owner.runId)
        XCTAssertNil(owner.completeOwnerKey)
        XCTAssertEqual(deltaText, "typing")

        let completeEvents = try routeIncomingEvents("assistant.message_complete", payloadJSON: """
        {
          "type": "assistant.message_complete",
          "messageId": "message-id-1"
        }
        """)
        let completeEvent = try XCTUnwrap(completeEvents.first)
        guard case .messageComplete(let owner) = completeEvent else {
            XCTFail("assistant.message_complete should map to .messageComplete")
            return
        }
        XCTAssertEqual(owner.messageId, "message-id-1")
        XCTAssertNil(owner.runId)
        XCTAssertNil(owner.completeOwnerKey)
    }

    func testAssistantMessageWithRunIdAndSessionKeyIsCompleteOwner() throws {
        let events = try routeIncomingEvents("assistant.message", payloadJSON: """
        {
          "type": "assistant.message",
          "messageId": "message-id-2",
          "runId": "run-3",
          "sessionKey": "agent:main:main",
          "content": "hello"
        }
        """)
        let event = try XCTUnwrap(events.first)
        guard case .message(let msg) = event else {
            XCTFail("assistant.message should map to .message")
            return
        }
        XCTAssertEqual(msg.owner?.messageId, "message-id-2")
        XCTAssertEqual(msg.owner?.runId, "run-3")
        XCTAssertEqual(msg.owner?.sessionKey, "agent:main:main")
        XCTAssertEqual(msg.owner?.completeOwnerKey?.sessionKey, "agent:main:main")
        XCTAssertEqual(msg.owner?.completeOwnerKey?.runId, "run-3")
    }

    func testMissingSessionKeyIsNotInferred() throws {
        let events = try routeIncomingEvents("chat", payloadJSON: """
        {
          "type": "chat",
          "state": "final",
          "runId": "run-4",
          "message": {
            "role": "assistant",
            "content": [{ "type": "text", "text": "hello" }]
          }
        }
        """)
        let event = try XCTUnwrap(events.first)
        guard case .message(let msg) = event else {
            XCTFail("chat final should map to .message when sessionKey is absent")
            return
        }
        XCTAssertNil(msg.owner?.sessionKey)
        XCTAssertNil(msg.owner?.completeOwnerKey)
    }

    func testCanonicalRunIdAcrossSessionsProducesDistinctCompleteOwnerKey() throws {
        let primaryEvents = try routeIncomingEvents("assistant.message", payloadJSON: """
        {
          "type": "assistant.message",
          "messageId": "message-id-1",
          "runId": "run-5",
          "sessionKey": "agent:main:main",
          "content": "hello"
        }
        """)
        let secondaryEvents = try routeIncomingEvents("assistant.message", payloadJSON: """
        {
          "type": "assistant.message",
          "messageId": "message-id-2",
          "runId": "run-5",
          "sessionKey": "agent:main:proactive:heartbeat",
          "content": "hello"
        }
        """)
        let primaryEvent = try XCTUnwrap(primaryEvents.first)
        let secondaryEvent = try XCTUnwrap(secondaryEvents.first)
        guard case .message(let primaryMessage) = primaryEvent,
              case .message(let secondaryMessage) = secondaryEvent else {
            XCTFail("assistant.message should map to .message")
            return
        }
        XCTAssertEqual(primaryMessage.owner?.completeOwnerKey?.sessionKey, "agent:main:main")
        XCTAssertEqual(primaryMessage.owner?.completeOwnerKey?.runId, "run-5")
        XCTAssertEqual(secondaryMessage.owner?.completeOwnerKey?.sessionKey, "agent:main:proactive:heartbeat")
        XCTAssertEqual(secondaryMessage.owner?.completeOwnerKey?.runId, "run-5")
        XCTAssertNotEqual(primaryMessage.owner?.completeOwnerKey, secondaryMessage.owner?.completeOwnerKey)
    }

    func testPetModelMessageFinalCorrelatesPendingSummonByOwnerRunIdNotMessageId() async throws {
        let model = PetModel()
        let baselineHashes = persistedJsonHashes()

        model.pendingSummonSource = "manual"
        model.pendingSummonRunId = "run-A"
        let beforeSummonResultsCount = model.summonResults.count

        let acceptedMessage = try XCTUnwrap(try routeIncomingEvents("assistant.message", payloadJSON: """
        {
          "type": "assistant.message",
          "messageId": "msg-1",
          "runId": "run-A",
          "sessionKey": "agent:main:main",
          "content": "accepted reply"
        }
        """).first)
        guard case .message(let msg) = acceptedMessage else {
            XCTFail("assistant.message should map to .message")
            return
        }
        model.handleEvent(.message(msg))
        await waitForMainQueue(2)

        XCTAssertNil(model.pendingSummonSource)
        XCTAssertNil(model.pendingSummonRunId)
        XCTAssertEqual(model.summonResults.count, beforeSummonResultsCount + 1)
        XCTAssertEqual(model.summonResults.last?.text, "accepted reply")
        XCTAssertEqual(model.summonResults.last?.source, "manual")
        let afterAcceptedHashes = persistedJsonHashes()
        XCTAssertNotEqual(baselineHashes["summon.json"], afterAcceptedHashes["summon.json"])
        assertNonSummonPersistenceUnchanged(before: baselineHashes, after: afterAcceptedHashes)

        let staleModel = PetModel()
        staleModel.pendingSummonSource = "manual"
        staleModel.pendingSummonRunId = "run-A"
        let staleSummonResultsCount = staleModel.summonResults.count

        let ignoredByRunId = try XCTUnwrap(try routeIncomingEvents("assistant.message", payloadJSON: """
        {
          "type": "assistant.message",
          "messageId": "msg-2",
          "runId": "run-B",
          "sessionKey": "agent:main:main",
          "content": "ignored because run id mismatched"
        }
        """).first)
        let ignoredByMissingRunId = try XCTUnwrap(try routeIncomingEvents("assistant.message", payloadJSON: """
        {
          "type": "assistant.message",
          "messageId": "msg-3",
          "sessionKey": "agent:main:main",
          "content": "ignored because run id absent"
        }
        """).first)
        guard case .message(let runMismatchMessage) = ignoredByRunId else {
            XCTFail("assistant.message should map to .message for run mismatch case")
            return
        }
        guard case .message(let absentRunMessage) = ignoredByMissingRunId else {
            XCTFail("assistant.message should map to .message for missing runId case")
            return
        }
        staleModel.handleEvent(.message(runMismatchMessage))
        staleModel.handleEvent(.message(absentRunMessage))
        await waitForMainQueue(2)

        XCTAssertEqual(staleModel.pendingSummonSource, "manual")
        XCTAssertEqual(staleModel.pendingSummonRunId, "run-A")
        XCTAssertEqual(staleModel.summonResults.count, staleSummonResultsCount)
        XCTAssertFalse(staleModel.messages.contains(where: { $0.text == "ignored because run id mismatched" }))
        XCTAssertFalse(staleModel.messages.contains(where: { $0.text == "ignored because run id absent" }))
        let finalHashes = persistedJsonHashes()
        assertNonSummonPersistenceUnchanged(before: afterAcceptedHashes, after: finalHashes)
        XCTAssertEqual(afterAcceptedHashes["summon.json"], finalHashes["summon.json"])
    }

    func testValidNormalSolDispatchAckPassesValidation() throws {
        let payload = try decodeIncomingPayload("""
        {
          "runId": "run-1",
          "sessionKey": "agent:main:main",
          "resolvedModel": "openai/gpt-5.6-sol",
          "resolvedThinking": "max",
          "degraded": false,
          "fallbackReason": null,
          "isolationApplied": true,
          "nonprojectionApplied": true,
          "resultRetentionExpiresAt": null
        }
        """)

        let ack = try PetLogDispatchAck.validate(from: payload)
        XCTAssertEqual(ack.runId, "run-1")
        XCTAssertEqual(ack.sessionKey, "agent:main:main")
        XCTAssertEqual(ack.resolvedModel, "openai/gpt-5.6-sol")
        XCTAssertEqual(ack.resolvedThinking, "max")
        XCTAssertEqual(ack.degraded, false)
        XCTAssertNil(ack.fallbackReason)
        XCTAssertTrue(ack.isolationApplied)
        XCTAssertTrue(ack.nonprojectionApplied)
    }

    func testValidTerraDispatchAckPassesValidation() throws {
        let payload = try decodeIncomingPayload("""
        {
          "runId": "run-2",
          "sessionKey": "agent:main:main",
          "resolvedModel": "openai/gpt-5.6-terra",
          "resolvedThinking": "max",
          "degraded": true,
          "fallbackReason": "rate_limited",
          "isolationApplied": true,
          "nonprojectionApplied": true,
          "resultRetentionExpiresAt": null
        }
        """)

        let ack = try PetLogDispatchAck.validate(from: payload)
        XCTAssertEqual(ack.runId, "run-2")
        XCTAssertEqual(ack.sessionKey, "agent:main:main")
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
