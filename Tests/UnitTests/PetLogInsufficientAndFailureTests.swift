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

    /// An insufficient reply: typed discriminator + null answer. Included is []
    /// for automatic, the exact-all echo for explicit (D145).
    private func insufficientReply(included: [String], confidence: String = "high") -> String {
        let idList = included.map { "\"\($0)\"" }.joined(separator: ",")
        let range = included.isEmpty ? "null" : "{\"startSegmentId\":\"\(included.first!)\",\"endSegmentId\":\"\(included.last!)\"}"
        return """
        {"outcome":"insufficientEvidence","answer":null,"contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
        "includedSegmentIds":[\(idList)],"includedRange":\(range),"excludedAdjacentRange":null,
        "boundaryReasonCodes":[],"boundaryConfidence":"\(confidence)","historyComplete":true,"correctionCounts":{}}}
        """
    }

    private func answerReply(answer: String, ids: [String]) -> String {
        let ans = String(data: try! JSONEncoder().encode(answer), encoding: .utf8)!
        let idList = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"outcome":"answer","answer":\(ans),"contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
        "includedSegmentIds":[\(idList)],"includedRange":{"startSegmentId":"\(ids.first!)","endSegmentId":"\(ids.last!)"},
        "excludedAdjacentRange":null,"boundaryReasonCodes":[],"boundaryConfidence":"high","historyComplete":true,"correctionCounts":{}}}
        """
    }

    // MARK: - Parser (typed discriminator, text-independent)

    func testAutomaticInsufficientIsAcceptedRegardlessOfConfidence() {
        // D147: automatic insufficient (empty inclusion) skips the answer gate —
        // low/medium confidence is fine, and no answer text is present.
        for confidence in ["high", "medium", "low"] {
            switch PetLogResultParser.parse(insufficientReply(included: [], confidence: confidence),
                                            allowedSegmentIds: ["a", "b", "c"], selectionMode: .automaticBackward) {
            case .success(let r): XCTAssertEqual(r.outcome, .insufficientEvidence)
            case .failure(let e): XCTFail("automatic insufficient (\(confidence)) must be accepted, got \(e)")
            }
        }
    }

    func testExplicitInsufficientRequiresExactAllEcho() {
        // D145: explicit insufficient must echo the whole scope, not empty.
        XCTAssertEqual(PetLogResultParser.parse(insufficientReply(included: []),
                                                allowedSegmentIds: ["a", "b", "c"], selectionMode: .explicitExact),
                       .failure(.insufficientInclusionMismatch))
        switch PetLogResultParser.parse(insufficientReply(included: ["a", "b", "c"]),
                                        allowedSegmentIds: ["a", "b", "c"], selectionMode: .explicitExact) {
        case .success(let r): XCTAssertEqual(r.outcome, .insufficientEvidence)
        case .failure(let e): XCTFail("explicit exact-all insufficient must be accepted, got \(e)")
        }
    }

    // MARK: - Client mapping

    func testInsufficientEvidenceBecomesStatusNotAReply() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let requestId = UUID().uuidString
        model.sendLogInstruction(envelope: automaticEnvelope(requestId: requestId, ids: ["a", "b", "c"]))
        model.addSummonResult(text: insufficientReply(included: []), source: "log", parseAsStructured: true)

        XCTAssertEqual(model.logDispatchStatus, .insufficientEvidence(requestId: requestId),
                       "insufficient evidence must surface as a typed status")
        XCTAssertFalse(model.logReplies.contains { $0.source == "log" },
                       "no ちー reply is persisted for an insufficient outcome")

        // Owner-scoped clear: an unrelated summon success must NOT clear it...
        model.addSummonResult(text: "some omakase output", source: "omakase")
        XCTAssertEqual(model.logDispatchStatus, .insufficientEvidence(requestId: requestId),
                       "an unrelated summon success must not clear the Log status")

        // ...but the NEXT accepted Log request does. (In production the terminal
        // event releases the slot before the reply is handled; here we release it
        // explicitly since addSummonResult bypasses that path.)
        model.pendingSummonSource = nil
        model.sendLogInstruction(envelope: automaticEnvelope(requestId: UUID().uuidString, ids: ["x"]))
        XCTAssertNil(model.logDispatchStatus, "the next accepted Log request clears the prior status")
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

    // MARK: - D16 over-budget refuse is fail-visible, never dispatched

    func testExplicitOverBudgetRefusesVisiblyWithoutDispatch() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true
        model.petLogRequestBudgetForTesting = 100  // below any real request (prefix alone is larger)

        let requestId = UUID().uuidString
        let env = PetLogQueryEnvelope(
            requestId: requestId, actionId: "slot-0", instruction: "このシーン",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: ["scene-1"],
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true,
            segments: [segment("a"), segment("b")])
        model.sendLogInstruction(envelope: env)

        XCTAssertEqual(model.logDispatchStatus, .overBudgetRefused(requestId: requestId),
                       "an explicit over-budget scope refuses visibly (exact-or-refuse)")
        XCTAssertFalse(model.logReplies.contains { $0.source == "log_user" },
                       "over-budget refuse must not create a log_user entry or dispatch")
        XCTAssertFalse(model.isSummonBusy, "no summon slot is claimed for a refused query")
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
        let reply = answerReply(answer: "x", ids: ["a"])
        model.addSummonResult(text: reply, source: "log", parseAsStructured: true)

        let entry = model.logReplies.last { $0.source == "log" }
        XCTAssertTrue(entry?.text.contains("unrecognized selection mode") ?? false,
                      "an unknown mode must fail closed, not be validated as automatic")
    }

    // MARK: - Prefix wording guard (empty/garble => typed insufficient, no body)

    /// The empty/garble selection instruction must route through the
    /// `insufficientEvidence` outcome with a null answer — never the old
    /// "write an answer that only states the log is insufficient" wording, which
    /// would tell the model to emit a body the parser then rejects.
    func testPrefixEmptyCaseRoutesToTypedInsufficientNotAnswerBody() {
        let prefix = PetLogPromptBuilder.universalPrefix()
        XCTAssertFalse(prefix.contains("旨のみを述べて"),
                       "the empty/garble case must not instruct writing an answer body")
        XCTAssertTrue(prefix.contains("項目を創作せず"),
                      "the empty/garble instruction must still be present")
        // The same instruction must now name the typed outcome and null answer.
        guard let range = prefix.range(of: "項目を創作せず") else {
            return XCTFail("empty/garble instruction missing")
        }
        let tail = String(prefix[range.lowerBound...].prefix(300))
        XCTAssertTrue(tail.contains("insufficientEvidence"),
                      "the empty/garble case must route to the insufficientEvidence outcome")
        XCTAssertTrue(tail.contains("null"),
                      "the empty/garble case must state answer is null")
    }
}
