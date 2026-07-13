import XCTest
@testable import ClawGate

/// Reproduces the 2026-07-13 18:42 JST incident: a "質問まとめ" (Log summarize)
/// request completed successfully server-side (task_complete + WS final sent),
/// but the reply never reached the Log pane. Root cause: the WS client's
/// ping-timeout reconnect churn tore down the connection mid-stream; the
/// client's 5s delta-idle timer then finalized the in-flight reply with only
/// the partial text accumulated so far, clearing `pendingSummonSource` before
/// the real final could arrive. The real final then fell through to the
/// generic chat path instead of the Log pane.
final class PetModelDisconnectRoutingTests: XCTestCase {
    private var originalIdleTimeoutNanos: UInt64 = 0

    override func setUp() {
        super.setUp()
        originalIdleTimeoutNanos = PetModel.deltaIdleTimeoutNanos
        PetModel.deltaIdleTimeoutNanos = 80_000_000 // 80ms, shrunk for fast/deterministic tests
    }

    override func tearDown() {
        PetModel.deltaIdleTimeoutNanos = originalIdleTimeoutNanos
        super.tearDown()
    }

    func testDisconnectMidStreamDoesNotTruncateOrDropPendingLogReply() async throws {
        let model = PetModel()
        model.pendingSummonSource = "log"

        // Two deltas for the same messageId: the first starts the stream, the
        // second is what actually (re)schedules the delta-idle finalize timer.
        model.handleEvent(.delta(messageId: "m1", text: "partial fragment"))
        model.handleEvent(.delta(messageId: "m1", text: " / 狙い:"))
        model.handleEvent(.disconnected(reason: "ping timeout"))

        // Let the (shortened) delta-idle window fully elapse — proves the
        // idle timer does not fire and truncate the pending reply.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Reconnect + resubscribe delivers the real, complete final.
        let fullMessage = OpenClawChatMessage(role: .assistant, text: "complete answer text")
        model.handleEvent(.message(fullMessage))
        try await Task.sleep(nanoseconds: 50_000_000)

        let logEntries = model.logReplies.filter { $0.source == "log" }
        XCTAssertEqual(logEntries.count, 1, "exactly one log reply should be recorded")
        XCTAssertEqual(logEntries.first?.text, "complete answer text",
                        "the full final text must reach the Log pane, not a mid-stream fragment")
        XCTAssertTrue(model.messages.isEmpty,
                       "the final must not fall through to the plain chat pane")
    }
}
