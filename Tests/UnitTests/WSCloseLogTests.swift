import XCTest
@testable import ClawGate

/// The client-side per-role close log. The Gateway cannot attribute its own
/// close rows to the Pet socket or the ambient ingest socket — both run under
/// one device id — so the role-separated durations come from here.
final class WSCloseLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawgate-wsclose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(role: String, connectedAt: Date?, closedAt: Date,
                       code: Int? = nil, reason: String = "quit") -> WSCloseLog.Entry {
        WSCloseLog.Entry(
            role: role, pid: 4242,
            connectedAt: connectedAt, closedAt: closedAt,
            durationSeconds: connectedAt.map { closedAt.timeIntervalSince($0) },
            reason: reason,
            observedCloseCode: code, connectAttempts: 1, generation: 3)
    }

    /// The whole point of the log: two sockets that overlap in time are still
    /// separable, which is exactly what the Gateway's single-identity rows are
    /// not. 2026-09-22: 72% of its inter-close gaps computed negative.
    func testOverlappingSocketsStaySeparableByRole() throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        // pet opens first and closes last; ingest lives entirely inside it.
        WSCloseLog.append(entry(role: "ingest", connectedAt: t0 + 30,
                                closedAt: t0 + 90, code: 1006), root: root)
        WSCloseLog.append(entry(role: "pet", connectedAt: t0,
                                closedAt: t0 + 120, code: 1001), root: root)

        let rows = WSCloseLog.recent(now: t0, root: root)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.role), ["ingest", "pet"], "oldest close first")
        XCTAssertEqual(rows.first { $0.role == "pet" }?.durationSeconds, 120)
        XCTAssertEqual(rows.first { $0.role == "ingest" }?.durationSeconds, 60)
        XCTAssertEqual(rows.first { $0.role == "pet" }?.observedCloseCode, 1001)
    }

    /// Regression: `teardown()` clears `connectedAt` at its top, long before the
    /// log line is written near its end. Reading the field there gave every row
    /// a nil duration — a log that silently measured nothing.
    func testADurationSurvivesEvenThoughTeardownClearsTheFieldFirst() throws {
        let opened = Date(timeIntervalSince1970: 1_790_000_000)
        let closed = opened + 42
        WSCloseLog.append(entry(role: "pet", connectedAt: opened, closedAt: closed), root: root)

        let rows = WSCloseLog.recent(now: opened, root: root)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].durationSeconds, 42)
    }

    /// The path that closed the socket has to be on the row: a 1005 seen on the
    /// quit path and a 1005 seen from a watchdog mean different things, and
    /// without this the observed code has to be attributed by guesswork.
    func testTheClosingPathIsRecordedAlongsideTheCode() throws {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        WSCloseLog.append(entry(role: "pet", connectedAt: t, closedAt: t + 7.5,
                                code: 1005, reason: "quit"), root: root)
        WSCloseLog.append(entry(role: "pet", connectedAt: t + 10, closedAt: t + 120,
                                code: 1006, reason: "frame-watchdog"), root: root)

        let rows = WSCloseLog.recent(now: t, root: root)

        XCTAssertEqual(rows.map(\.reason), ["quit", "frame-watchdog"])
        XCTAssertEqual(rows[0].observedCloseCode, 1005)
        XCTAssertEqual(rows[1].observedCloseCode, 1006)
    }

    /// A connect that never completed is worth a line too, and a nil duration
    /// there is the truth rather than a lost value.
    func testAFailedAttemptIsRecordedWithNoDuration() throws {
        let closed = Date(timeIntervalSince1970: 1_790_000_000)
        WSCloseLog.append(entry(role: "ingest", connectedAt: nil, closedAt: closed), root: root)

        let rows = WSCloseLog.recent(now: closed, root: root)

        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].connectedAt)
        XCTAssertNil(rows[0].durationSeconds)
    }

    func testAnUndecodableLineIsSkippedInsteadOfFailingTheRead() throws {
        let closed = Date(timeIntervalSince1970: 1_790_000_000)
        WSCloseLog.append(entry(role: "pet", connectedAt: closed - 5, closedAt: closed), root: root)
        let file = WSCloseLog.recent(now: closed, root: root)
        XCTAssertEqual(file.count, 1)

        let day = try XCTUnwrap(FileManager.default
            .contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".jsonl") })
        let url = root.appendingPathComponent(day)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("{ not json\n".utf8))
        try? handle.close()

        XCTAssertEqual(WSCloseLog.recent(now: closed, root: root).count, 1,
                       "the good line survives a corrupt neighbour")
    }
}
