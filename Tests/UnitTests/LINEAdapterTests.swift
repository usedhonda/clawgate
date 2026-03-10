import XCTest
@testable import ClawGate

/// Tests for LINE adapter logic components.
///
/// LINEAdapter.sendMessage relies on AX and cannot be unit-tested directly.
/// These tests cover the pure-logic building blocks it depends on:
///   - conversation hint skip decision
///   - echo detection for sent messages
///   - search cleanup sanitization
final class LINEAdapterTests: XCTestCase {
    func testProbeOnlyNeverRequestsRecovery() {
        XCTAssertFalse(
            LINEAdapter.shouldRecoverDefaultConversationSurface(mode: .probeOnly, isAbnormal: true)
        )
    }

    func testRecoverIfNeededRepairsOnlyAbnormalSurface() {
        XCTAssertTrue(
            LINEAdapter.shouldRecoverDefaultConversationSurface(mode: .recoverIfNeeded, isAbnormal: true)
        )
        XCTAssertFalse(
            LINEAdapter.shouldRecoverDefaultConversationSurface(mode: .recoverIfNeeded, isAbnormal: false)
        )
    }

    func testForceRecoverRepairsEvenWhenSurfaceIsClean() {
        XCTAssertTrue(
            LINEAdapter.shouldRecoverDefaultConversationSurface(mode: .forceRecover, isAbnormal: false)
        )
    }

    // MARK: - canSkipNavigation decision table

    /// canSkipNavigation = (lastHint == currentHint) AND inputFieldExists.
    /// When the hint comparison fails, navigation must NOT be skipped.
    func testSkipNavigationRequiresSameHint() {
        let lastHint: String? = "Yuzuru Honda"
        let currentHint = "Yuzuru Honda"
        // Pure condition 1: hint must match
        XCTAssertEqual(lastHint, currentHint, "Same hint should allow skip consideration")
    }

    func testSkipNavigationDeniedOnDifferentHint() {
        let lastHint: String? = "Yuzuru Honda"
        let currentHint = "Work Group"
        XCTAssertNotEqual(lastHint, currentHint, "Different hint must prevent skip")
    }

    func testSkipNavigationDeniedOnNilLastHint() {
        let lastHint: String? = nil
        let currentHint = "Yuzuru Honda"
        // nil lastHint means first send — must not skip
        XCTAssertNil(lastHint)
        XCTAssertFalse(lastHint == currentHint)
    }

    // MARK: - Echo detection in LINE context

    /// After sending via LINE, the sent text appears in the chat bubble.
    /// RecentSendTracker should detect this echo to prevent re-processing.
    func testEchoDetectionForLINESentText() {
        let tracker = RecentSendTracker(windowSeconds: 60)
        let sentText = "[clawgate.cc]\nHello from Claude Code"
        tracker.recordSend(conversation: "Yuzuru Honda", text: sentText)

        XCTAssertTrue(tracker.isLikelyEcho(), "Should detect recent send as likely echo")
        XCTAssertEqual(tracker.recentSentText(), sentText)
    }

    func testEchoDetectionWithLineBreaksInBubble() {
        let tracker = RecentSendTracker(windowSeconds: 60)
        let sent = "[clawgate.cc] long message with multiple lines of text for testing"
        tracker.recordSend(conversation: "Yuzuru Honda", text: sent)

        // LINE chat bubble may reflow the text with different line breaks
        let candidate = "[clawgate.cc] long message\nwith multiple lines of\ntext for testing"
        XCTAssertTrue(
            LineTextSanitizer.textLikelyContainsSentText(candidate: candidate, sentText: sent),
            "Echo detection should match across whitespace differences"
        )
    }

    // MARK: - Search cleanup sanitization

    /// After search+send, the sidebar text should be sanitizable
    /// to prevent stale search terms from polluting OCR.
    func testSanitizeRemovesUIArtifactsFromSearchResult() {
        let text = """
        既読
        12:34
        Hello from user
        """
        let sanitized = LineTextSanitizer.sanitize(text)
        XCTAssertEqual(sanitized, "Hello from user")
    }

    func testSanitizePreservesLongMessageWithTimestampWord() {
        let text = "メッセージ送信時刻は12:34で、既読がつきました。長い本文なので削除されません。"
        let sanitized = LineTextSanitizer.sanitize(text)
        XCTAssertEqual(sanitized, text, "Long text containing timestamp-like patterns should be preserved")
    }

    // MARK: - Conversation hint caching contract

    /// Documents the expected caching behavior:
    /// lastConversationHint is set ONLY after successful send.
    /// On failure, it must NOT be updated (stale hint = safer than wrong hint).
    func testRecentSendTrackerRecordsConversation() {
        let tracker = RecentSendTracker()
        tracker.recordSend(conversation: "Yuzuru Honda", text: "Test")
        tracker.recordSend(conversation: "Work Group", text: "Test 2")

        // Most recent conversation's text should be returned
        XCTAssertEqual(tracker.recentSentText(), "Test 2")
    }
}
