import XCTest
@testable import ClawGate

final class StatsCollectorTests: XCTestCase {
    private var tempFile: String!

    override func setUp() {
        super.setUp()
        tempFile = NSTemporaryDirectory() + "clawgate-stats-test-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempFile)
        super.tearDown()
    }

    func testIncrementAndReadBack() {
        let collector = StatsCollector(filePath: tempFile)
        collector.increment("sent", adapter: "line")
        collector.increment("sent", adapter: "line")
        collector.increment("received", adapter: "line")

        let today = collector.today()
        XCTAssertEqual(today.lineSent, 2)
        XCTAssertEqual(today.lineReceived, 1)
        XCTAssertEqual(today.tmuxSent, 0)
    }

    func testTmuxMetrics() {
        let collector = StatsCollector(filePath: tempFile)
        collector.increment("sent", adapter: "tmux")
        collector.increment("completion", adapter: "tmux")
        collector.increment("completion", adapter: "tmux")
        collector.increment("question", adapter: "tmux")

        let today = collector.today()
        XCTAssertEqual(today.tmuxSent, 1)
        XCTAssertEqual(today.tmuxCompletion, 2)
        XCTAssertEqual(today.tmuxQuestion, 1)
    }

    func testApiRequestsCounting() {
        let collector = StatsCollector(filePath: tempFile)
        for _ in 0..<10 {
            collector.increment("api_requests", adapter: "system")
        }
        XCTAssertEqual(collector.today().apiRequests, 10)
    }

    func testTimestamps() {
        let collector = StatsCollector(filePath: tempFile)
        XCTAssertNil(collector.today().firstEventAt)

        collector.increment("sent", adapter: "line")
        let stats = collector.today()
        XCTAssertNotNil(stats.firstEventAt)
        XCTAssertNotNil(stats.lastEventAt)
    }

    func testHandleEventInboundLine() {
        let collector = StatsCollector(filePath: tempFile)
        let event = BridgeEvent(id: 1, type: "inbound_message", adapter: "line", payload: [:], observedAt: "2026-02-10T00:00:00Z")
        collector.handleEvent(event)
        XCTAssertEqual(collector.today().lineReceived, 1)
    }

    func testHandleEventEchoLine() {
        let collector = StatsCollector(filePath: tempFile)
        let event = BridgeEvent(id: 1, type: "echo_message", adapter: "line", payload: [:], observedAt: "2026-02-10T00:00:00Z")
        collector.handleEvent(event)
        XCTAssertEqual(collector.today().lineEcho, 1)
    }

    func testHandleEventTmuxCompletion() {
        let collector = StatsCollector(filePath: tempFile)
        let event = BridgeEvent(id: 1, type: "inbound_message", adapter: "tmux", payload: ["source": "completion"], observedAt: "2026-02-10T00:00:00Z")
        collector.handleEvent(event)
        XCTAssertEqual(collector.today().tmuxCompletion, 1)
    }

    func testHandleEventTmuxQuestion() {
        let collector = StatsCollector(filePath: tempFile)
        let event = BridgeEvent(id: 1, type: "inbound_message", adapter: "tmux", payload: ["source": "question"], observedAt: "2026-02-10T00:00:00Z")
        collector.handleEvent(event)
        XCTAssertEqual(collector.today().tmuxQuestion, 1)
    }

    func testJsonPersistence() {
        // Write stats
        let collector1 = StatsCollector(filePath: tempFile)
        collector1.increment("sent", adapter: "line")
        collector1.increment("received", adapter: "line")
        collector1.increment("sent", adapter: "tmux")

        // Load from same file in new instance
        let collector2 = StatsCollector(filePath: tempFile)
        let stats = collector2.today()
        XCTAssertEqual(stats.lineSent, 1)
        XCTAssertEqual(stats.lineReceived, 1)
        XCTAssertEqual(stats.tmuxSent, 1)
    }

    func testHistoryExcludesToday() {
        let collector = StatsCollector(filePath: tempFile)
        collector.increment("sent", adapter: "line")

        let history = collector.history(count: 7)
        // Today's data should not appear in history
        XCTAssertTrue(history.isEmpty)
    }

    func testUnknownMetricIgnored() {
        let collector = StatsCollector(filePath: tempFile)
        collector.increment("unknown_metric", adapter: "line")
        let stats = collector.today()
        // Should still have timestamps but no metric bumped
        XCTAssertEqual(stats.lineSent, 0)
        XCTAssertEqual(stats.lineReceived, 0)
    }
}
