import XCTest
@testable import ClawGate

/// D16: request-budget enforcement (deterministic whole-segment elision) and
/// overlap dedup. Budgets are chosen from measured `buildMessage` sizes so the
/// tests are self-calibrating and independent of the exact prefix length.
final class PetLogRequestBudgetTests: XCTestCase {
    private func raw(_ id: String, at: Double, text: String) -> PetLogRawSegment {
        PetLogRawSegment(id: id, capturedAt: at, startSeconds: 0, endSeconds: 1,
                         speaker: "A", text: text)
    }

    private func envelope(scopeOverride: [String]?, segments: [PetLogRawSegment]) -> PetLogQueryEnvelope {
        let epochs = segments.compactMap(\.capturedAt)
        return PetLogQueryEnvelope(
            requestId: "req-1", actionId: "free", instruction: "まとめて",
            queryTimestamp: Date(timeIntervalSince1970: 10_000),
            anchorTimestamp: Date(timeIntervalSince1970: 10_000),
            scopeOverride: scopeOverride,
            coverageStart: epochs.min().map { Date(timeIntervalSince1970: $0) },
            coverageEnd: epochs.max().map { Date(timeIntervalSince1970: $0) },
            completeBeforeAnchor: true, segments: segments)
    }

    private func bytes(_ e: PetLogQueryEnvelope) -> Int {
        (try? PetLogPromptBuilder.buildMessage(envelope: e))?.utf8.count ?? 0
    }

    // A large per-segment body so a few segments dominate the prefix size.
    private let big = String(repeating: "あ", count: 500)

    /// A request under budget passes through UNCHANGED (no transformation).
    func testUnderBudgetReturnsUnchangedEnvelope() {
        let env = envelope(scopeOverride: nil, segments: [
            raw("s0", at: 1000, text: "短い"), raw("s1", at: 1001, text: "短い2"),
        ])
        switch PetLogRequestEnforcer.enforce(env, budget: PetLogRequestBudget.maxRequestBytes) {
        case .fits(let out): XCTAssertEqual(out, env, "a fitting envelope is returned unchanged")
        default: XCTFail("a small envelope must fit")
        }
    }

    /// Automatic over-budget drops the OLDEST whole segments (keeping the
    /// anchor-nearest) and reports the dropped id range; coverageStart follows.
    func testAutomaticOverBudgetDropsOldestKeepsNewest() {
        let segs = (0..<6).map { raw("s\($0)", at: 1000 + Double($0), text: big) }
        let env = envelope(scopeOverride: nil, segments: segs)
        let budget = bytes(env.withSegments(Array(segs.suffix(4))))  // fits newest 4, not all 6
        switch PetLogRequestEnforcer.enforce(env, budget: budget) {
        case .compressed(let out, let droppedFirst, let droppedLast):
            XCTAssertEqual(out.segments.map(\.id), ["s2", "s3", "s4", "s5"],
                           "only the newest run that fits is kept")
            XCTAssertEqual(out.segments.last?.id, "s5", "the anchor-nearest segment is always kept")
            XCTAssertEqual(droppedFirst, "s0")
            XCTAssertEqual(droppedLast, "s1", "the dropped id range covers the oldest elided run")
            XCTAssertEqual(out.coverageStart, Date(timeIntervalSince1970: 1002),
                           "coverageStart reflects the trimmed (sent) range, no new field")
        default:
            XCTFail("automatic over-budget must trim, not refuse")
        }
    }

    /// Explicit (user-selected) scope over budget refuses — never silently
    /// narrowed into a false exact-scope.
    func testExplicitOverBudgetRefuses() {
        let segs = (0..<4).map { raw("s\($0)", at: 1000 + Double($0), text: big) }
        let env = envelope(scopeOverride: ["scene-1"], segments: segs)
        let budget = bytes(env.withSegments(Array(segs.suffix(2))))
        XCTAssertEqual(PetLogRequestEnforcer.enforce(env, budget: budget),
                       .refused(.explicitScopeOverBudget))
    }

    /// If even the newest single segment can't fit, refuse (both modes) rather
    /// than dispatch an over-limit request.
    func testMinimalRequestOverBudgetRefuses() {
        let segs = (0..<3).map { raw("s\($0)", at: 1000 + Double($0), text: big) }
        let env = envelope(scopeOverride: nil, segments: segs)
        let budget = bytes(env.withSegments([segs.last!])) - 1
        XCTAssertEqual(PetLogRequestEnforcer.enforce(env, budget: budget),
                       .refused(.minimalRequestOverBudget))
    }

    /// D16(a): an overlapping same-content re-emit is dropped (keep earlier); a
    /// legitimate repeat at disjoint times is kept.
    func testDedupOverlapDropsReemitKeepsDisjointRepeat() {
        func s(_ t: String, _ at: Double, _ dur: Double) -> TranscriptSegment {
            var x = TranscriptSegment(startSeconds: 0, endSeconds: dur, text: t)
            x.capturedAt = at; x.speaker = "A"; return x
        }
        let input = [
            s("はい", 100, 2),   // window [100, 102]
            s("はい", 101, 2),   // starts inside [100,102] → re-emit, dropped
            s("はい", 200, 2),   // disjoint → a real second utterance, kept
        ]
        let out = PetLogSegmentReducer.dedupOverlap(input)
        XCTAssertEqual(out.map(\.capturedAt), [100, 200],
                       "overlapping re-emit dropped, disjoint repeat kept")
    }
}
