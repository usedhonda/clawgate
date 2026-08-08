import XCTest
@testable import ClawGate

/// D3 (insufficient-evidence + fail-fast) and D72 (parser-failure metadata
/// retention). Abstract synthetic data only.
final class PetLogInsufficientAndFailureTests: XCTestCase {
    private func segment(_ id: String) -> PetLogRawSegment {
        PetLogRawSegment(id: id, capturedAt: nil, startSeconds: 0, endSeconds: 1, speaker: nil, text: "x")
    }

    private func automaticEnvelope(requestId: String, ids: [String]) -> PetLogQueryEnvelope {
        PetLogQueryEnvelope(
            requestId: requestId, actionId: "slot-0", instruction: "質問まとめ",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true,
            segments: ids.map(segment))
    }

    private func emptyIncludedReply(answer: String, confidence: String = "high") -> String {
        let ans = String(data: try! JSONEncoder().encode(answer), encoding: .utf8)!
        return """
        {"answer":\(ans),"contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
        "includedSegmentIds":[],"includedRange":null,"excludedAdjacentRange":null,
        "boundaryReasonCodes":[],"boundaryConfidence":"\(confidence)","historyComplete":true,"correctionCounts":{}}}
        """
    }

    // MARK: - Parser (structural, text-independent)

    func testAutomaticEmptyInclusionWithSentSegmentsIsInsufficient() {
        // Two different answer texts — the outcome is structural, not a text match.
        for answer in ["根拠となるログが不足しています", "totally unrelated prose"] {
            XCTAssertEqual(PetLogResultParser.parse(emptyIncludedReply(answer: answer),
                                                    allowedSegmentIds: ["a", "b", "c"], selectionMode: .automaticBackward),
                           .failure(.insufficientEvidence))
        }
    }

    func testExplicitEmptyInclusionIsScopeViolationNotInsufficient() {
        XCTAssertEqual(PetLogResultParser.parse(emptyIncludedReply(answer: "x"),
                                                allowedSegmentIds: ["a", "b", "c"], selectionMode: .explicitExact),
                       .failure(.explicitScopeRequiresExactInclusion))
    }

    // MARK: - Client mapping

    func testInsufficientEvidenceBecomesStatusNotAReply() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let requestId = UUID().uuidString
        model.sendLogInstruction(envelope: automaticEnvelope(requestId: requestId, ids: ["a", "b", "c"]))
        model.addSummonResult(text: emptyIncludedReply(answer: "根拠不足"), source: "log", parseAsStructured: true)

        XCTAssertEqual(model.logDispatchStatus, .insufficientEvidence(requestId: requestId),
                       "insufficient evidence must surface as a typed status")
        XCTAssertFalse(model.logReplies.contains { $0.source == "log" && $0.text.contains("根拠不足") },
                       "the model body must not be persisted as a ちー reply")
        XCTAssertFalse(model.logReplies.contains { $0.source == "log" && $0.text == "根拠不足" })
    }

    func testEmptyScopeEnvelopeIsRefusedFastAsStatus() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let requestId = UUID().uuidString
        model.sendLogInstruction(envelope: automaticEnvelope(requestId: requestId, ids: []))

        XCTAssertEqual(model.logDispatchStatus, .emptyScopeRefused(requestId: requestId))
        XCTAssertFalse(model.logReplies.contains { $0.source == "log_user" },
                       "an empty-scope query must not create a log_user entry or dispatch")
        XCTAssertFalse(model.isSummonBusy, "no slot is claimed for an empty-scope query")
    }

    // MARK: - D72 parser-failure metadata retention

    func testMalformedReplyRetainsRequestCorrelationMetadata() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let requestId = UUID().uuidString
        let ids = ["a", "b", "c"]
        model.sendLogInstruction(envelope: automaticEnvelope(requestId: requestId, ids: ids))
        model.addSummonResult(text: "not valid json", source: "log", parseAsStructured: true)

        guard let entry = model.logReplies.last(where: { $0.source == "log" }),
              let meta = entry.logMetadata else {
            return XCTFail("a malformed reply must still persist an entry with metadata")
        }
        XCTAssertTrue(entry.text.contains("did not match"))
        XCTAssertEqual(meta.requestId, requestId, "correlation must match the request")
        XCTAssertEqual(meta.sourceFingerprint,
                       PetLogSourceFingerprint.make(policyVersion: PetLogPromptBuilder.policyVersion, segmentIds: ids))
        XCTAssertNil(meta.contextDecision, "no fabricated model verdict on failure")
    }

    // MARK: - D148 unknown selection mode fails closed

    func testUnknownSelectionModeFailsClosed() {
        let model = PetModel()
        // Establish a pending request with a typo'd selection mode.
        model.pendingSummonSource = "log"
        model.setPendingLogRequestForTesting(segmentIds: ["a"], completeBeforeAnchor: true, selectionMode: "future")

        // Even a well-formed reply must be rejected — the mode is unrecognized.
        let reply = """
        {"answer":"x","contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
        "includedSegmentIds":["a"],"includedRange":{"startSegmentId":"a","endSegmentId":"a"},
        "excludedAdjacentRange":null,"boundaryReasonCodes":[],"boundaryConfidence":"high",
        "historyComplete":true,"correctionCounts":{}}}
        """
        model.addSummonResult(text: reply, source: "log", parseAsStructured: true)

        let entry = model.logReplies.last { $0.source == "log" }
        XCTAssertTrue(entry?.text.contains("unrecognized selection mode") ?? false,
                      "an unknown mode must fail closed, not be validated as automatic")
    }
}
