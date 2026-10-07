import XCTest
@testable import ClawGate

final class LineOCRFailureTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testPersistentRecognitionFailureReachesTheFaultThreshold() {
        var tracker = LineOCRFailureTracker()
        for _ in 0..<LineOCRFailureTracker.faultThreshold {
            XCTAssertFalse(tracker.isFaulted)
            tracker.recordFailure(reason: "incomplete_recognition", at: now)
        }
        XCTAssertTrue(tracker.isFaulted)
        XCTAssertEqual(tracker.reason, "incomplete_recognition")
        XCTAssertEqual(tracker.since, now)
    }

    func testOneSuccessClearsTheStreak() {
        var tracker = LineOCRFailureTracker()
        for _ in 0..<(LineOCRFailureTracker.faultThreshold + 3) { tracker.recordFailure(reason: "vision_error", at: now) }
        XCTAssertTrue(tracker.isFaulted)
        tracker.recordSuccess()
        XCTAssertFalse(tracker.isFaulted)
        XCTAssertEqual(tracker.streak, 0)
        XCTAssertEqual(tracker.reason, "")
        XCTAssertNil(tracker.since)
    }

    func testAnUncertainDetectorOrAnEmptyReasonNeverCounts() {
        var tracker = LineOCRFailureTracker()
        for _ in 0..<(LineOCRFailureTracker.faultThreshold * 2) {
            tracker.recordFailure(reason: InboundBubbleOCR.RecognizeFailure.detectorUncertain.rawValue, at: now)
            tracker.recordFailure(reason: "", at: now)
        }
        XCTAssertEqual(tracker.streak, 0)
        XCTAssertFalse(tracker.isFaulted)
    }

    func testANeutralPollInTheMiddleDoesNotResetAFaultingStreak() {
        var tracker = LineOCRFailureTracker()
        for _ in 0..<5 { tracker.recordFailure(reason: "atlas_failed", at: now) }
        tracker.recordFailure(reason: InboundBubbleOCR.RecognizeFailure.detectorUncertain.rawValue, at: now)
        for _ in 0..<5 { tracker.recordFailure(reason: "atlas_failed", at: now) }
        XCTAssertTrue(tracker.isFaulted)
    }
}
