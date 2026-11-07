import XCTest
@testable import ClawGate

final class RecentSendTrackerTests: XCTestCase {

    func testRecordedSendIsAvailableForEchoDetection() {
        let cases = [
            (RecentSendTracker(), "TestUser", "Hello"),
            (RecentSendTracker(windowSeconds: 60), "Alice Smith", "[clawgate.cc]\nHello from Claude Code"),
        ]
        for (tracker, conversation, text) in cases {
            tracker.recordSend(conversation: conversation, text: text)
            XCTAssertTrue(tracker.isLikelyEcho())
            XCTAssertEqual(tracker.recentSentText(), text)
        }
    }

    func testIsLikelyEchoWhenEmpty() {
        let tracker = RecentSendTracker()
        XCTAssertFalse(tracker.isLikelyEcho())
    }

    func testRecentSentTextNilWhenEmpty() {
        let tracker = RecentSendTracker()
        XCTAssertNil(tracker.recentSentText())
    }

    func testRecentSentTextReturnsNewest() {
        // Keep both the two-conversation and three-send sequences in one
        // newest-entry contract; this does not test LINE's navigation cache.
        let sequences = [
            [("User1", "First"), ("User2", "Second"), ("User3", "Third")],
            [("Alice Smith", "Test"), ("Work Group", "Test 2")],
        ]
        for sequence in sequences {
            let tracker = RecentSendTracker()
            for (conversation, text) in sequence {
                tracker.recordSend(conversation: conversation, text: text)
                XCTAssertEqual(tracker.recentSentText(), text)
            }
        }
    }

    func testLastSendAtTracksLatestRecordedSend() {
        var now = Date(timeIntervalSince1970: 1_000)
        let tracker = RecentSendTracker(nowProvider: { now })
        XCTAssertNil(tracker.lastSendAt)

        tracker.recordSend(conversation: "User1", text: "First")
        let first = tracker.lastSendAt
        XCTAssertNotNil(first)

        now = now.addingTimeInterval(15)
        tracker.recordSend(conversation: "User2", text: "Second")
        let second = tracker.lastSendAt
        XCTAssertNotNil(second)
        XCTAssertTrue((second ?? .distantPast) >= (first ?? .distantPast))
    }

    func testSentWithinUsesLastRecordedSendTime() {
        var now = Date(timeIntervalSince1970: 2_000)
        let tracker = RecentSendTracker(nowProvider: { now })

        tracker.recordSend(conversation: "User1", text: "First")
        XCTAssertTrue(tracker.sentWithin(seconds: 60))

        now = now.addingTimeInterval(61)
        XCTAssertFalse(tracker.sentWithin(seconds: 60))
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
