import XCTest
@testable import ClawGate

/// D2 / D41 / D52 parser contract fixtures. Abstract synthetic data only — no
/// real conversation content.
final class PetLogParserContractTests: XCTestCase {
    /// Builds a schema-valid reply JSON. `range` defaults to first/last of
    /// `included` (nil when empty).
    private func reply(answer: String = "まとめ", included: [String],
                       confidence: String = "high",
                       reasonCodes: [String] = [], corrections: [String: Int] = [:],
                       excluded: (String, String)? = nil) -> String {
        func obj(_ p: (String, String)?) -> String {
            guard let p else { return "null" }
            return "{\"startSegmentId\":\"\(p.0)\",\"endSegmentId\":\"\(p.1)\"}"
        }
        let range: (String, String)? = included.isEmpty ? nil : (included.first!, included.last!)
        let idList = included.map { "\"\($0)\"" }.joined(separator: ",")
        let rc = reasonCodes.map { "\"\($0)\"" }.joined(separator: ",")
        let cc = corrections.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        let ans = String(data: try! JSONEncoder().encode(answer), encoding: .utf8)!
        return """
        {"outcome":"answer","answer":\(ans),"contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
        "includedSegmentIds":[\(idList)],"includedRange":\(obj(range)),
        "excludedAdjacentRange":\(obj(excluded)),"boundaryReasonCodes":[\(rc)],
        "boundaryConfidence":"\(confidence)","historyComplete":true,"correctionCounts":{\(cc)}}}
        """
    }

    private func ids(_ n: Int) -> [String] { (0..<n).map { "seg-\($0)" } }

    // MARK: - D2 incident (explicit scope)

    /// The Aug-4 incident, abstracted: ~300 sent segments under an explicit
    /// scene scope, model returns 1 of N (high, scope-override-applied). Under
    /// explicitExact this is now a scope violation (old-fail: the pre-D2 parser
    /// accepted it).
    func testExplicitScopeRejectsOneOfManyIncident() {
        let allowed = ids(300)
        let json = reply(included: [allowed[0]], reasonCodes: ["scope-override-applied"])
        XCTAssertEqual(PetLogResultParser.parse(json, allowedSegmentIds: allowed, selectionMode: .explicitExact),
                       .failure(.explicitScopeRequiresExactInclusion))
    }

    /// 契約詳細 guard (1): a 700-segment explicit query with exact-all inclusion
    /// (in order) is accepted.
    func testExplicitScopeAcceptsExactAllInclusion() {
        let allowed = ids(700)
        let json = reply(included: allowed)
        switch PetLogResultParser.parse(json, allowedSegmentIds: allowed, selectionMode: .explicitExact) {
        case .success(let r): XCTAssertEqual(r.contextDecision.includedSegmentIds.count, 700)
        case .failure(let e): XCTFail("exact-all explicit inclusion must be accepted, got \(e)")
        }
    }

    // MARK: - D2 automatic (backward suffix)

    func testAutomaticRejectsGappedAndNewestSkippingSubsets() {
        let allowed = ["a", "b", "c", "d"]
        // gapped [a,c,d]
        XCTAssertEqual(PetLogResultParser.parse(reply(included: ["a", "c", "d"]), allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.notContiguousBackwardSuffix))
        // newest-skipping [a]
        XCTAssertEqual(PetLogResultParser.parse(reply(included: ["a"]), allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.notContiguousBackwardSuffix))
        // valid suffix [c,d] with the full dropped prefix [a,b] declared (D142)
        switch PetLogResultParser.parse(reply(included: ["c", "d"], excluded: ("a", "b")), allowedSegmentIds: allowed, selectionMode: .automaticBackward) {
        case .success: break
        case .failure(let e): XCTFail("valid suffix must be accepted, got \(e)")
        }
    }

    // MARK: - D41 duplicate ids

    func testRejectsDuplicateAllowedAndIncludedIds() {
        XCTAssertEqual(PetLogResultParser.parse(reply(included: ["a"]), allowedSegmentIds: ["a", "a", "b"], selectionMode: .automaticBackward),
                       .failure(.duplicateAllowedIds))
        // duplicate included ids (allowed unique)
        let dupIncluded = reply(included: ["b", "b"])
        XCTAssertEqual(PetLogResultParser.parse(dupIncluded, allowedSegmentIds: ["a", "b"], selectionMode: .automaticBackward),
                       .failure(.duplicateIncludedIds))
    }

    // MARK: - D52 bounds (limit ±1)

    func testAnswerLengthBound() {
        let allowed = ["a", "b"]
        let atLimit = reply(answer: String(repeating: "x", count: PetLogResponseBounds.maxAnswerChars), included: allowed)
        switch PetLogResultParser.parse(atLimit, allowedSegmentIds: allowed, selectionMode: .automaticBackward) {
        case .success: break
        case .failure(let e): XCTFail("answer at the limit must pass, got \(e)")
        }
        let over = reply(answer: String(repeating: "x", count: PetLogResponseBounds.maxAnswerChars + 1), included: allowed)
        XCTAssertEqual(PetLogResultParser.parse(over, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.answerTooLong))
    }

    func testReasonCodeCountBound() {
        let allowed = ["a", "b"]
        let at = reply(included: allowed, reasonCodes: (0..<PetLogResponseBounds.maxReasonCodes).map { "r\($0)" })
        switch PetLogResultParser.parse(at, allowedSegmentIds: allowed, selectionMode: .automaticBackward) {
        case .success: break
        case .failure(let e): XCTFail("reason codes at the limit must pass, got \(e)")
        }
        let over = reply(included: allowed, reasonCodes: (0...PetLogResponseBounds.maxReasonCodes).map { "r\($0)" })
        XCTAssertEqual(PetLogResultParser.parse(over, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.tooManyReasonCodes))
    }

    private func expectSuccess(_ json: String, _ allowed: [String], _ label: String) {
        switch PetLogResultParser.parse(json, allowedSegmentIds: allowed, selectionMode: .automaticBackward) {
        case .success: break
        case .failure(let e): XCTFail("\(label) at the limit must pass, got \(e)")
        }
    }

    func testReasonCodeLengthBound() {
        let allowed = ["a", "b"]
        expectSuccess(reply(included: allowed, reasonCodes: [String(repeating: "c", count: PetLogResponseBounds.maxReasonCodeChars)]),
                      allowed, "reason code length")
        let over = reply(included: allowed, reasonCodes: [String(repeating: "c", count: PetLogResponseBounds.maxReasonCodeChars + 1)])
        XCTAssertEqual(PetLogResultParser.parse(over, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.reasonCodeTooLong))
    }

    func testCorrectionKeyCountBound() {
        let allowed = ["a", "b"]
        var atKeys: [String: Int] = [:]
        for i in 0..<PetLogResponseBounds.maxCorrectionKeys { atKeys["k\(i)"] = 0 }
        expectSuccess(reply(included: allowed, corrections: atKeys), allowed, "correction key count")
        var overKeys = atKeys; overKeys["extra"] = 0
        XCTAssertEqual(PetLogResultParser.parse(reply(included: allowed, corrections: overKeys), allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.tooManyCorrectionKeys))
    }

    func testCorrectionKeyLengthBound() {
        let allowed = ["a", "b"]
        expectSuccess(reply(included: allowed, corrections: [String(repeating: "k", count: PetLogResponseBounds.maxCorrectionKeyChars): 0]),
                      allowed, "correction key length")
        let over = reply(included: allowed, corrections: [String(repeating: "k", count: PetLogResponseBounds.maxCorrectionKeyChars + 1): 0])
        XCTAssertEqual(PetLogResultParser.parse(over, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.correctionKeyTooLong))
    }

    func testCorrectionValueBound() {
        let allowed = ["a", "b"]
        expectSuccess(reply(included: allowed, corrections: ["k": PetLogResponseBounds.maxCorrectionValue]), allowed, "correction value")
        let over = reply(included: allowed, corrections: ["k": PetLogResponseBounds.maxCorrectionValue + 1])
        XCTAssertEqual(PetLogResultParser.parse(over, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.correctionValueOutOfRange))
    }

    // MARK: - D146 raw byte preflight

    func testRawByteBoundPreflight() {
        let allowed = ["a", "b"]
        // The byte preflight runs before JSON parsing, so probe its boundary with
        // raw payloads (a valid reply can never reach the cap — every field is
        // bounded well below it). Exactly at the limit passes the preflight (then
        // fails JSON parse); one byte over is rejected by the preflight itself.
        let atLimit = String(repeating: "z", count: PetLogResponseBounds.maxResponseBytes)
        XCTAssertNotEqual(PetLogResultParser.parse(atLimit, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                          .failure(.responseTooLarge), "exactly at the byte limit must pass the preflight")
        let over = String(repeating: "z", count: PetLogResponseBounds.maxResponseBytes + 1)
        XCTAssertEqual(PetLogResultParser.parse(over, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.responseTooLarge))
        // A huge unknown-key JSON is rejected by bytes before deserialization.
        let hugeJSON = "{\"junk\":\"" + String(repeating: "z", count: PetLogResponseBounds.maxResponseBytes) + "\"}"
        XCTAssertEqual(PetLogResultParser.parse(hugeJSON, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.responseTooLarge))
    }

    // MARK: - D147 / D150 discriminator ↔ shape integrity

    func testDiscriminatorAnswerIntegrity() {
        let allowed = ["a", "b"]
        // insufficient must not carry a body.
        let insufficientWithBody = """
        {"outcome":"insufficientEvidence","answer":"本文","contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
        "includedSegmentIds":[],"includedRange":null,"excludedAdjacentRange":null,"boundaryReasonCodes":[],
        "boundaryConfidence":"high","historyComplete":true,"correctionCounts":{}}}
        """
        XCTAssertEqual(PetLogResultParser.parse(insufficientWithBody, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.insufficientMustHaveNullAnswer))
        // answer must not be null.
        let answerNull = """
        {"outcome":"answer","answer":null,"contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
        "includedSegmentIds":["a","b"],"includedRange":{"startSegmentId":"a","endSegmentId":"b"},"excludedAdjacentRange":null,
        "boundaryReasonCodes":[],"boundaryConfidence":"high","historyComplete":true,"correctionCounts":{}}}
        """
        XCTAssertEqual(PetLogResultParser.parse(answerNull, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.answerOutcomeRequiresAnswer))
        // D150: insufficient must not claim an excluded (boundary) range.
        let insufficientExcluded = """
        {"outcome":"insufficientEvidence","answer":null,"contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
        "includedSegmentIds":[],"includedRange":null,"excludedAdjacentRange":{"startSegmentId":"a","endSegmentId":"a"},
        "boundaryReasonCodes":[],"boundaryConfidence":"high","historyComplete":true,"correctionCounts":{}}}
        """
        XCTAssertEqual(PetLogResultParser.parse(insufficientExcluded, allowedSegmentIds: allowed, selectionMode: .automaticBackward),
                       .failure(.insufficientMustHaveNullExcluded))
    }
}
