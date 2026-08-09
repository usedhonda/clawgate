import XCTest
@testable import ClawGate

/// D38 (past-day cache invalidation) and D92 (poll timer idempotency).
final class AmbientLogCacheAndTimerTests: XCTestCase {
    private let jst = TimeZone(identifier: "Asia/Tokyo")!

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawgate-daycache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSession(_ id: String, _ segs: [TranscriptSegment], under root: URL) throws {
        let dir = root.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        let lines = try segs.map { String(data: try enc.encode($0), encoding: .utf8)! }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: dir.appendingPathComponent("raw.jsonl"))
    }

    private func seg(_ text: String, at capturedAt: Double) -> TranscriptSegment {
        var s = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: text)
        s.capturedAt = capturedAt
        return s
    }

    private func startOfDayJST(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = jst
        return cal.startOfDay(for: date)
    }

    // MARK: - D38 day fingerprint (cache invalidation signal)

    /// The day fingerprint is stable when the day's raw is unchanged and changes
    /// when a late write grows it — the signal that invalidates a cached past day.
    func testDayFingerprintChangesOnLateAppendStableOtherwise() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 5; c.hour = 12; c.timeZone = jst
        let day = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(day).timeIntervalSince1970
        let before = (1...20).map { seg("s\($0)", at: dayStart + Double($0)) }
        try writeSession("ctx-day", before, under: root)

        let fp1 = AmbientStorage.dayFingerprint(forDay: startOfDayJST(day), timeZone: jst, sessionsRoot: root)
        let fp1again = AmbientStorage.dayFingerprint(forDay: startOfDayJST(day), timeZone: jst, sessionsRoot: root)
        XCTAssertEqual(fp1, fp1again, "the fingerprint is stable when nothing changed (no needless invalidation)")

        // A late append (recovery/backfill) grows the day's raw.
        let after = before + (21...30).map { seg("s\($0)", at: dayStart + Double($0)) }
        try writeSession("ctx-day", after, under: root)
        let fp2 = AmbientStorage.dayFingerprint(forDay: startOfDayJST(day), timeZone: jst, sessionsRoot: root)
        XCTAssertNotEqual(fp1, fp2, "a late write to a past day changes its fingerprint (invalidates the cache)")
    }

    // MARK: - D92 poll timer idempotency

    func testStartIsIdempotentKeepingASingleTimer() {
        let model = AmbientLogModel()
        XCTAssertNil(model.pollTimerForTesting, "not polling before start")

        model.start()
        let t1 = model.pollTimerForTesting
        XCTAssertNotNil(t1, "polling after start")
        model.start()
        model.start()
        XCTAssertTrue(model.pollTimerForTesting === t1,
                      "repeated start() must keep the same single timer, not leak new ones")

        model.stop()
        XCTAssertNil(model.pollTimerForTesting, "stop() clears the timer")

        model.start()
        XCTAssertNotNil(model.pollTimerForTesting, "start after stop arms a fresh timer")
        model.stop()
    }
}
