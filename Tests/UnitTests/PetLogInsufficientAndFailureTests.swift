import XCTest
@testable import ClawGate

/// D3 (insufficient-evidence + fail-fast) and D72 (parser-failure metadata
/// retention). Abstract synthetic data only.
final class PetLogInsufficientAndFailureTests: XCTestCase {
    private var originalLogStoreDir = ""

    // A dispatched (accepted) Log request persists a log_user entry through
    // PetLogStore — redirect it to a throwaway temp dir so a test never writes
    // to the user's real ~/.clawgate/logs/*.json (2026-07-14 data-loss incident).
    override func setUp() {
        super.setUp()
        PetLogStore.testIsolationSemaphore.wait()
        originalLogStoreDir = PetLogStore.dir
        PetLogStore.dir = NSTemporaryDirectory() + "clawgate-test-logs-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: PetLogStore.dir)
        PetLogStore.dir = originalLogStoreDir
        PetLogStore.testIsolationSemaphore.signal()
        super.tearDown()
    }

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
    private func insufficientReply(included: [String], confidence: String = "high",
                                   historyComplete: Bool = true) -> String {
        let idList = included.map { "\"\($0)\"" }.joined(separator: ",")
        let range = included.isEmpty ? "null" : "{\"startSegmentId\":\"\(included.first!)\",\"endSegmentId\":\"\(included.last!)\"}"
        return """
        {"outcome":"insufficientEvidence","answer":null,"contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
        "includedSegmentIds":[\(idList)],"includedRange":\(range),"excludedAdjacentRange":null,
        "boundaryReasonCodes":[],"boundaryConfidence":"\(confidence)","historyComplete":\(historyComplete),"correctionCounts":{}}}
        """
    }

    /// A truncated-before-coverage automatic ANSWER that trims a real leading
    /// prefix. `included` is the kept backward suffix; `excluded` the dropped
    /// prefix range; `reasonCodes` the boundary justification.
    private func truncatedAnswer(included: [String], excluded: (String, String)?,
                                 reasonCodes: [String], confidence: String = "high") -> String {
        let idList = included.map { "\"\($0)\"" }.joined(separator: ",")
        let range = included.isEmpty ? "null" : "{\"startSegmentId\":\"\(included.first!)\",\"endSegmentId\":\"\(included.last!)\"}"
        let ex = excluded.map { "{\"startSegmentId\":\"\($0.0)\",\"endSegmentId\":\"\($0.1)\"}" } ?? "null"
        let reasons = reasonCodes.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"outcome":"answer","answer":"ok","contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
        "includedSegmentIds":[\(idList)],"includedRange":\(range),"excludedAdjacentRange":\(ex),
        "boundaryReasonCodes":[\(reasons)],"boundaryConfidence":"\(confidence)","historyComplete":false,"correctionCounts":{}}}
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

    // MARK: - D16/D20 fail-closed: incomplete history is never dispatched

    /// Over-budget refuses fail-closed before any side-effect (no log_user entry,
    /// no slot claim, no dispatch).
    func testOverBudgetRefusesFailClosedWithoutDispatch() {
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

        XCTAssertEqual(model.logDispatchStatus, .historyIncompleteRefused(requestId: requestId),
                       "over budget refuses fail-closed with a typed status")
        XCTAssertFalse(model.logReplies.contains { $0.source == "log_user" },
                       "refuse must not create a log_user entry or dispatch")
        XCTAssertFalse(model.isSummonBusy, "no summon slot is claimed for a refused query")
    }

    /// D153: an automatic query truncated before its coverage is DISPATCHED with
    /// the wire flag set — it is NOT refused. The model, seeing the flag, decides
    /// answer-with-boundary vs insufficient. Only over-budget / the
    /// explicit-truncated invariant refuse.
    func testAutomaticTruncatedDispatchesWithFlagNotRefused() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let requestId = UUID().uuidString
        let env = PetLogQueryEnvelope(
            requestId: requestId, actionId: "free", instruction: "まとめて",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true,
            segments: [segment("a"), segment("b")], retrievalTruncatedBeforeCoverage: true)
        let accepted = model.sendLogInstruction(envelope: env)

        XCTAssertTrue(accepted, "a truncated automatic query dispatches, it is not refused")
        XCTAssertTrue(model.logReplies.contains { $0.source == "log_user" },
                      "the send reaches the dispatch path (a log_user entry is created)")
        XCTAssertNil(model.logDispatchStatus, "no refusal status for a dispatched truncated query")
    }

    /// D153 client invariant: an EXPLICIT scope can never be truncated (it is
    /// day-scoped exact-all). A truncated explicit envelope is a client bug —
    /// refused before dispatch with no side effect.
    func testExplicitTruncatedRefusesAsInvariantViolation() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let requestId = UUID().uuidString
        let env = PetLogQueryEnvelope(
            requestId: requestId, actionId: "slot-0", instruction: "このシーン",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: ["scene-1"],
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true,
            segments: [segment("a"), segment("b")], retrievalTruncatedBeforeCoverage: true)
        let accepted = model.sendLogInstruction(envelope: env)

        XCTAssertFalse(accepted, "explicit + truncated is an invariant violation, refused")
        XCTAssertEqual(model.logDispatchStatus, .historyIncompleteRefused(requestId: requestId))
        XCTAssertFalse(model.logReplies.contains { $0.source == "log_user" },
                       "refuse creates no log_user entry")
    }

    /// D159/D163: a source-read-incomplete envelope refuses before dispatch with
    /// a typed status — no log_user entry, no slot claim, draft preserved.
    func testSourceReadIncompleteRefusesBeforeDispatch() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let requestId = UUID().uuidString
        var env = PetLogQueryEnvelope(
            requestId: requestId, actionId: "free", instruction: "まとめて",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true,
            segments: [segment("a"), segment("b")])
        env.sourceReadIncomplete = true
        let accepted = model.sendLogInstruction(envelope: env)

        XCTAssertFalse(accepted, "a source-read-incomplete query is refused, never dispatched")
        XCTAssertEqual(model.logDispatchStatus, .sourceReadIncompleteRefused(requestId: requestId))
        XCTAssertFalse(model.logReplies.contains { $0.source == "log_user" },
                       "refuse creates no log_user entry")
        XCTAssertFalse(model.isSummonBusy, "no summon slot is claimed for a refused query")
    }

    // MARK: - D153 truncated-before-coverage parser branches

    /// A truncated automatic answer must TRIM a real leading prefix — full
    /// inclusion (the model "found no boundary" yet answered) is rejected.
    func testTruncatedAnswerRejectsFullInclusion() {
        let reply = truncatedAnswer(included: ["a", "b", "c"], excluded: nil, reasonCodes: ["x"])
        XCTAssertEqual(PetLogResultParser.parse(reply, allowedSegmentIds: ["a", "b", "c"],
                                                selectionMode: .automaticBackward, truncatedBeforeCoverage: true),
                       .failure(.truncatedAnswerRequiresBoundaryTrim))
    }

    /// A truncated automatic answer must justify the boundary with reason codes.
    func testTruncatedAnswerRejectsMissingReasonCodes() {
        let reply = truncatedAnswer(included: ["b", "c"], excluded: ("a", "a"), reasonCodes: [])
        XCTAssertEqual(PetLogResultParser.parse(reply, allowedSegmentIds: ["a", "b", "c"],
                                                selectionMode: .automaticBackward, truncatedBeforeCoverage: true),
                       .failure(.truncatedAnswerRequiresReasonCodes))
    }

    /// A truncated automatic answer with a real boundary trim + reason codes +
    /// high confidence is accepted.
    func testTruncatedAnswerAcceptedWithBoundary() {
        let reply = truncatedAnswer(included: ["b", "c"], excluded: ("a", "a"), reasonCodes: ["scene-change"])
        switch PetLogResultParser.parse(reply, allowedSegmentIds: ["a", "b", "c"],
                                        selectionMode: .automaticBackward, truncatedBeforeCoverage: true) {
        case .success(let res): XCTAssertEqual(res.outcome, .answer)
        case .failure(let e): XCTFail("a boundary-trimmed truncated answer must be accepted, got \(e)")
        }
    }

    /// A truncated automatic insufficient must assert incomplete history — the
    /// case where earlier context is missing. historyComplete=true is rejected.
    func testTruncatedInsufficientRequiresIncompleteHistory() {
        let bad = insufficientReply(included: [], historyComplete: true)
        XCTAssertEqual(PetLogResultParser.parse(bad, allowedSegmentIds: ["a", "b", "c"],
                                                selectionMode: .automaticBackward, truncatedBeforeCoverage: true),
                       .failure(.truncatedInsufficientRequiresIncompleteHistory))

        let good = insufficientReply(included: [], historyComplete: false)
        switch PetLogResultParser.parse(good, allowedSegmentIds: ["a", "b", "c"],
                                        selectionMode: .automaticBackward, truncatedBeforeCoverage: true) {
        case .success(let res): XCTAssertEqual(res.outcome, .insufficientEvidence)
        case .failure(let e): XCTFail("truncated insufficient with historyComplete=false must be accepted, got \(e)")
        }
    }

    /// Non-truncated automatic replies are unchanged by the D153 branch (a full
    /// answer with no trim is still valid when the request wasn't truncated).
    func testNonTruncatedAnswerUnaffectedByTruncatedRules() {
        let reply = answerReply(answer: "まとめ", ids: ["a", "b", "c"])
        switch PetLogResultParser.parse(reply, allowedSegmentIds: ["a", "b", "c"],
                                        selectionMode: .automaticBackward, truncatedBeforeCoverage: false) {
        case .success(let res): XCTAssertEqual(res.outcome, .answer)
        case .failure(let e): XCTFail("a non-truncated full answer must still be accepted, got \(e)")
        }
    }

    /// D16 refusal position: an over-budget request refuses fail-closed BEFORE the
    /// busy admission check — the typed status wins, and no busy "Error" marker
    /// is appended, so nothing side-effects while a prior summon is in flight.
    func testOverBudgetRefusesBeforeBusyAdmissionWithNoSideEffect() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true
        model.petLogRequestBudgetForTesting = 100  // below the prefix alone
        model.pendingSummonSource = "scene"        // a prior summon is in flight (busy)
        let priorReplyCount = model.logReplies.count

        let requestId = UUID().uuidString
        let env = PetLogQueryEnvelope(
            requestId: requestId, actionId: "free", instruction: "まとめて",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true,
            segments: [segment("a"), segment("b")])
        let accepted = model.sendLogInstruction(envelope: env)

        XCTAssertFalse(accepted, "an over-budget request is refused, never dispatched")
        XCTAssertEqual(model.logDispatchStatus, .historyIncompleteRefused(requestId: requestId),
                       "over-budget is evaluated before busy — the typed status wins")
        XCTAssertEqual(model.logReplies.count, priorReplyCount,
                       "no log_user entry and no 'Error: busy' marker for an over-budget refusal")
        XCTAssertEqual(model.pendingSummonSource, "scene",
                       "the over-budget refusal never disturbs the in-flight summon slot")
    }

    /// D16 refusal position: an over-budget request refuses BEFORE the
    /// not-connected admission check too — no "Error: not connected" marker, so
    /// the draft is left intact even while offline.
    func testOverBudgetRefusesBeforeNotConnectedAdmissionWithNoSideEffect() {
        let model = PetModel()
        model.connectionState = .disconnected
        model.suppressLogSendForTesting = true
        model.petLogRequestBudgetForTesting = 100
        let priorReplyCount = model.logReplies.count

        let requestId = UUID().uuidString
        let env = PetLogQueryEnvelope(
            requestId: requestId, actionId: "free", instruction: "まとめて",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true,
            segments: [segment("a"), segment("b")])
        let accepted = model.sendLogInstruction(envelope: env)

        XCTAssertFalse(accepted, "an over-budget request is refused, never dispatched")
        XCTAssertEqual(model.logDispatchStatus, .historyIncompleteRefused(requestId: requestId),
                       "over-budget is evaluated before the not-connected check")
        XCTAssertEqual(model.logReplies.count, priorReplyCount,
                       "no 'Error: not connected' marker is appended for an over-budget refusal")
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
