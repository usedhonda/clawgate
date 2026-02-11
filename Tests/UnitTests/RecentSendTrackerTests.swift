import XCTest
@testable import ClawGate

final class RecentSendTrackerTests: XCTestCase {

    func testIsLikelyEchoAfterSend() {
        let tracker = RecentSendTracker()
        tracker.recordSend(conversation: "TestUser", text: "Hello")
        XCTAssertTrue(tracker.isLikelyEcho())
    }

    func testIsLikelyEchoWhenEmpty() {
        let tracker = RecentSendTracker()
        XCTAssertFalse(tracker.isLikelyEcho())
    }

    func testRecentSentTextReturnsLatest() {
        let tracker = RecentSendTracker()
        tracker.recordSend(conversation: "TestUser", text: "Hello")
        XCTAssertEqual(tracker.recentSentText(), "Hello")
    }

    func testRecentSentTextNilWhenEmpty() {
        let tracker = RecentSendTracker()
        XCTAssertNil(tracker.recentSentText())
    }

    func testRecentSentTextReturnsNewest() {
        let tracker = RecentSendTracker()
        tracker.recordSend(conversation: "User1", text: "First")
        tracker.recordSend(conversation: "User2", text: "Second")
        tracker.recordSend(conversation: "User3", text: "Third")
        XCTAssertEqual(tracker.recentSentText(), "Third")
    }

    func testConcurrentAccessDoesNotCrash() {
        let tracker = RecentSendTracker()
        let group = DispatchGroup()

        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                tracker.recordSend(conversation: "User", text: "msg-\(i)")
                _ = tracker.isLikelyEcho()
                _ = tracker.recentSentText()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent access should not crash or deadlock")
    }

    func testIsLikelyEchoByTextMatch() {
        let tracker = RecentSendTracker(windowSeconds: 60)
        tracker.recordSend(conversation: "TestUser", text: "これは非常に長いテキストです command line sample 12345")
        XCTAssertTrue(tracker.isLikelyEcho(text: "これは非常に長いテキストです\ncommand line sample 12345\n既読"))
    }

    func testIsLikelyEchoByTextMatchRequiresEnoughSignal() {
        let tracker = RecentSendTracker(windowSeconds: 60)
        tracker.recordSend(conversation: "TestUser", text: "ok")
        XCTAssertFalse(tracker.isLikelyEcho(text: "ok"))
    }
}
