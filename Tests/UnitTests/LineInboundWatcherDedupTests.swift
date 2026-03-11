import XCTest
@testable import ClawGate

final class LineInboundWatcherDedupTests: XCTestCase {
    func testSameLineMovedUpwardSuppressesAndTrackerFollowsNewY() {
        let now = Date(timeIntervalSince1970: 1_000)
        let tracker = [
            "same line": LineSeenPositionEntry(
                normalizedLine: "same line",
                latestSeenY: 600,
                lastSeenAt: now.addingTimeInterval(-5)
            )
        ]

        let (evaluation, updatedTracker) = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: false,
            fragments: [fragment("same line", display: "Same line", y: 540, order: 0)],
            tracker: tracker,
            freshness: noFreshness(),
            now: now
        )

        XCTAssertTrue(evaluation.shouldSuppress)
        XCTAssertEqual(evaluation.reason, "suppressed_same_or_above_y")
        XCTAssertEqual(updatedTracker["same line"]?.latestSeenY, 540)
    }

    func testSameLineLowerOnScreenIsAcceptedAsNewMessage() {
        let now = Date(timeIntervalSince1970: 1_000)
        let tracker = [
            "same line": LineSeenPositionEntry(
                normalizedLine: "same line",
                latestSeenY: 480,
                lastSeenAt: now.addingTimeInterval(-30)
            )
        ]

        let (evaluation, updatedTracker) = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: false,
            fragments: [fragment("same line", display: "Same line", y: 650, order: 0)],
            tracker: tracker,
            freshness: noFreshness(),
            now: now
        )

        XCTAssertFalse(evaluation.shouldSuppress)
        XCTAssertEqual(evaluation.reason, "accepted_line_y_progress")
        XCTAssertEqual(evaluation.emittedText, "Same line")
        XCTAssertEqual(updatedTracker["same line"]?.latestSeenY, 650)
    }

    func testBottomMostYWinsWhenSameLineAppearsTwiceInOnePoll() {
        let collapsed = LineInboundDedupDecisionEngine.collapseObservedFragments([
            fragment("same line", display: "Same line", y: 420, order: 1),
            fragment("same line", display: "Same line", y: 610, order: 2),
        ])

        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed.first?.observedY, 610)
    }

    func testMixedOldAndNewLinesEmitOnlyNovelLowerLine() {
        let now = Date(timeIntervalSince1970: 1_000)
        let tracker = [
            "old line": LineSeenPositionEntry(
                normalizedLine: "old line",
                latestSeenY: 560,
                lastSeenAt: now.addingTimeInterval(-20)
            )
        ]

        let (evaluation, updatedTracker) = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: false,
            fragments: [
                fragment("old line", display: "Old line", y: 520, order: 0),
                fragment("new line", display: "New line", y: 620, order: 1),
            ],
            tracker: tracker,
            freshness: noFreshness(),
            now: now
        )

        XCTAssertFalse(evaluation.shouldSuppress)
        XCTAssertEqual(evaluation.emittedText, "New line")
        XCTAssertEqual(evaluation.acceptedLineCount, 1)
        XCTAssertEqual(updatedTracker["old line"]?.latestSeenY, 520)
        XCTAssertEqual(updatedTracker["new line"]?.latestSeenY, 620)
    }

    func testPrimaryEvidenceWithoutPositionedLinesDoesNotEmit() {
        let freshness = LineInboundFreshnessEvidence(
            incomingRows: 1,
            bottomChanged: false,
            newestSliceUsed: false,
            cursorStatus: .applied,
            postCursorNovelLineCount: 0,
            pixelTextChanged: false
        )

        let (evaluation, _) = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: false,
            fragments: [],
            tracker: [:],
            freshness: freshness,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertTrue(evaluation.shouldSuppress)
        XCTAssertEqual(evaluation.reason, "suppressed_primary_without_position")
    }

    func testCursorNotFoundWithoutPositionedLinesIsNeutralSuppress() {
        let freshness = LineInboundFreshnessEvidence(
            incomingRows: 0,
            bottomChanged: false,
            newestSliceUsed: false,
            cursorStatus: .notFound,
            postCursorNovelLineCount: 0,
            pixelTextChanged: true
        )

        let (evaluation, _) = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: false,
            fragments: [],
            tracker: [:],
            freshness: freshness,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertTrue(evaluation.shouldSuppress)
        XCTAssertEqual(evaluation.reason, "suppressed_cursor_neutral")
    }

    func testFingerprintWindowStillSuppressesImmediateDuplicates() {
        let (evaluation, updatedTracker) = LineInboundDedupDecisionEngine.decide(
            fingerprintHit: true,
            fragments: [fragment("same line", display: "Same line", y: 600, order: 0)],
            tracker: [:],
            freshness: noFreshness(),
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertTrue(evaluation.shouldSuppress)
        XCTAssertEqual(evaluation.reason, "suppressed_fingerprint_window")
        XCTAssertTrue(updatedTracker.isEmpty)
    }

    func testPruneKeepsEntriesWithin24HoursOnly() {
        let now = Date(timeIntervalSince1970: 100_000)
        let entries = [
            "old": LineSeenPositionEntry(
                normalizedLine: "old",
                latestSeenY: 100,
                lastSeenAt: now.addingTimeInterval(-(24 * 60 * 60) - 1)
            ),
            "fresh": LineSeenPositionEntry(
                normalizedLine: "fresh",
                latestSeenY: 200,
                lastSeenAt: now.addingTimeInterval(-60)
            )
        ]

        let pruned = LineInboundDedupDecisionEngine.prune(entries: entries, now: now, ttl: 24 * 60 * 60)

        XCTAssertEqual(Set(pruned.keys), ["fresh"])
    }

    private func fragment(_ normalized: String, display: String, y: Int, order: Int) -> LineObservedFragment {
        LineObservedFragment(
            normalizedLine: normalized,
            displayText: display,
            observedY: y,
            source: "test",
            order: order
        )
    }

    private func noFreshness() -> LineInboundFreshnessEvidence {
        LineInboundFreshnessEvidence(
            incomingRows: 0,
            bottomChanged: false,
            newestSliceUsed: false,
            cursorStatus: .applied,
            postCursorNovelLineCount: 0,
            pixelTextChanged: false
        )
    }
}
