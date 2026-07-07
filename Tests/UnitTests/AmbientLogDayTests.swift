import XCTest
@testable import ClawGate

/// Day-scoped transcript readout: `AmbientStorage.segments(forDay:timeZone:)`
/// merges every session's kept segments for one local calendar day, selecting
/// by each segment's `capturedAt` (sessions can straddle midnight).
final class AmbientLogDayTests: XCTestCase {
    private let jst = TimeZone(identifier: "Asia/Tokyo")!
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawgate-ambient-day-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // Anchor day: 2026-06-10 12:00 JST (Wednesday).
    private func anchorDay() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 10; c.hour = 12
        c.timeZone = jst
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func dayStartEpoch() -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jst
        return cal.startOfDay(for: anchorDay()).timeIntervalSince1970
    }

    private func seg(_ text: String, at capturedAt: Double?) -> TranscriptSegment {
        var s = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: text)
        s.capturedAt = capturedAt
        return s
    }

    /// Write one session's raw.jsonl; optionally backdate the file mod time to
    /// exercise the old-session cutoff.
    @discardableResult
    private func writeSession(_ id: String, _ segs: [TranscriptSegment], modDate: Date? = nil) throws -> URL {
        let dir = tmpRoot
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("raw.jsonl")
        let enc = JSONEncoder()
        let lines = try segs.map { String(data: try enc.encode($0), encoding: .utf8)! }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: raw)
        if let modDate {
            try FileManager.default.setAttributes([.modificationDate: modDate], ofItemAtPath: raw.path)
        }
        return raw
    }

    private func run() -> [TranscriptSegment] {
        AmbientStorage.segments(forDay: anchorDay(), timeZone: jst, sessionsRoot: tmpRoot)
    }

    func testDayBoundarySelectsSegmentsAroundLocalMidnight() throws {
        let start = dayStartEpoch()
        let end = start + 86_400
        try writeSession("ctx-boundary", [
            seg("prevDay", at: start - 1),      // 23:59:59 the day before → excluded
            seg("atStart", at: start),          // 00:00:00 → included (inclusive lower bound)
            seg("justAfter", at: start + 1),    // included
            seg("beforeEnd", at: end - 1),      // 23:59:59 → included
            seg("nextDay", at: end),            // 00:00:00 next day → excluded (exclusive upper bound)
        ])
        XCTAssertEqual(run().map(\.text), ["atStart", "justAfter", "beforeEnd"])
    }

    func testMergesMultipleSessionsAndSortsByCapturedAt() throws {
        let start = dayStartEpoch()
        try writeSession("ctx-a", [
            seg("a-late", at: start + 300),
            seg("a-early", at: start + 100),
        ])
        try writeSession("ctx-b", [
            seg("b-mid", at: start + 200),
        ])
        XCTAssertEqual(run().map(\.text), ["a-early", "b-mid", "a-late"])
    }

    func testLegacyLinesWithoutCapturedAtAreExcluded() throws {
        let start = dayStartEpoch()
        try writeSession("ctx-legacy", [
            seg("legacy", at: nil),
            seg("stamped", at: start + 50),
        ])
        XCTAssertEqual(run().map(\.text), ["stamped"])
    }

    func testNoMatchingDayReturnsEmpty() throws {
        let start = dayStartEpoch()
        try writeSession("ctx-prev", [
            seg("prevOnly", at: start - 3600),  // entirely the previous day
        ])
        XCTAssertTrue(run().isEmpty)
    }

    func testOldModDateSessionIsSkippedEvenIfSegmentMatches() throws {
        let start = dayStartEpoch()
        // Fresh session (default mod time = now) with an in-day segment: read.
        try writeSession("ctx-fresh", [seg("fresh", at: start + 10)])
        // Old session whose raw.jsonl mod time predates the day, yet contains a
        // segment whose capturedAt falls inside the day. The mod-date cutoff must
        // skip the file, so "leak" must never surface (proves the file is unread).
        try writeSession(
            "ctx-old",
            [seg("leak", at: start + 20)],
            modDate: Date(timeIntervalSince1970: start - 3600))
        XCTAssertEqual(run().map(\.text), ["fresh"])
    }
}
