import XCTest
@testable import ClawGate

final class LineInboundWatcherDedupTests: XCTestCase {
    func testPrimaryEvidenceOverridesContentMemory() {
        let freshness = LineInboundFreshnessEvidence(
            incomingRows: 1,
            bottomChanged: false,
            newestSliceUsed: false,
            cursorStatus: .applied,
            postCursorNovelLineCount: 0,
            pixelTextChanged: false
        )

        let decision = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: false,
            contentMemoryHit: true,
            freshness: freshness
        )

        XCTAssertFalse(decision.shouldSuppress)
        XCTAssertEqual(decision.reason, "accepted_primary_evidence")
    }

    func testFingerprintWindowStillSuppressesImmediateDuplicates() {
        let freshness = LineInboundFreshnessEvidence(
            incomingRows: 1,
            bottomChanged: true,
            newestSliceUsed: true,
            cursorStatus: .applied,
            postCursorNovelLineCount: 2,
            pixelTextChanged: true
        )

        let decision = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: true,
            contentMemoryHit: false,
            freshness: freshness
        )

        XCTAssertTrue(decision.shouldSuppress)
        XCTAssertEqual(decision.reason, "suppressed_fingerprint_window")
    }

    func testCursorNotFoundIsNeutralSuppressWithoutFreshEvidence() {
        let freshness = LineInboundFreshnessEvidence(
            incomingRows: 0,
            bottomChanged: false,
            newestSliceUsed: false,
            cursorStatus: .notFound,
            postCursorNovelLineCount: 0,
            pixelTextChanged: true
        )

        let decision = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: false,
            contentMemoryHit: false,
            freshness: freshness
        )

        XCTAssertTrue(decision.shouldSuppress)
        XCTAssertEqual(decision.reason, "suppressed_cursor_neutral")
    }

    func testBottomChangedNewestSliceCountsAsPrimaryEvidence() {
        let freshness = LineInboundFreshnessEvidence(
            incomingRows: 0,
            bottomChanged: true,
            newestSliceUsed: true,
            cursorStatus: .applied,
            postCursorNovelLineCount: 0,
            pixelTextChanged: true
        )

        let decision = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: false,
            contentMemoryHit: true,
            freshness: freshness
        )

        XCTAssertFalse(decision.shouldSuppress)
        XCTAssertEqual(decision.reason, "accepted_primary_evidence")
        XCTAssertEqual(freshness.primaryReason, "bottom_changed_newest_slice")
    }

    func testContentMemoryAssistSuppressesWhenNoPrimaryEvidence() {
        let freshness = LineInboundFreshnessEvidence(
            incomingRows: 0,
            bottomChanged: false,
            newestSliceUsed: false,
            cursorStatus: .applied,
            postCursorNovelLineCount: 0,
            pixelTextChanged: false
        )

        let decision = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: false,
            contentMemoryHit: true,
            freshness: freshness
        )

        XCTAssertTrue(decision.shouldSuppress)
        XCTAssertEqual(decision.reason, "suppressed_content_memory_assist")
    }

    func testContentMemoryPruneExpiresOldEntries() {
        let now = Date(timeIntervalSince1970: 1_000)
        let entries = [
            LineSeenEntry(normalizedLine: "old", seenAt: now.addingTimeInterval(-91)),
            LineSeenEntry(normalizedLine: "fresh", seenAt: now.addingTimeInterval(-30)),
        ]

        let pruned = LineInboundDedupDecisionEngine.prune(entries: entries, now: now, ttl: 90)

        XCTAssertEqual(pruned.map(\.normalizedLine), ["fresh"])
    }
}
