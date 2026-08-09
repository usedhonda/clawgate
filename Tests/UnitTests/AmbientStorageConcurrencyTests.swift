import XCTest
@testable import ClawGate

/// D42: `AmbientStorage.segments(...)` runs off the main thread (D21) and can be
/// called concurrently for different days/roots, so the shared session cache
/// must be race-safe. These stress the locked cache under parallel poll+query
/// load and during a late write.
final class AmbientStorageConcurrencyTests: XCTestCase {
    private let jst = TimeZone(identifier: "Asia/Tokyo")!

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawgate-concurrency-\(UUID().uuidString)", isDirectory: true)
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

    /// poll (segments(forDay:)) + query (segmentsBackwardFromAnchor) run 100x in
    /// parallel across two roots; every read must return the correct count.
    func testPollAndQueryParallel100xConsistent() throws {
        let rootA = makeRoot(); let rootB = makeRoot()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }

        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 1; c.hour = 12; c.timeZone = jst
        let day = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(day).timeIntervalSince1970
        let nA = 300, nB = 120
        try writeSession("ctx-a", (1...nA).map { seg("a\($0)", at: dayStart + Double($0)) }, under: rootA)
        try writeSession("ctx-b", (1...nB).map { seg("b\($0)", at: dayStart + Double($0)) }, under: rootB)
        let anchor = Date(timeIntervalSince1970: dayStart + Double(max(nA, nB)) + 10)

        let mismatches = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            let useA = (i % 2 == 0)
            let root = useA ? rootA : rootB
            let expected = useA ? nA : nB
            let poll = AmbientStorage.segments(forDay: startOfDayJST(day), timeZone: jst, sessionsRoot: root)
            // The whole day is one contiguous run (1s apart), so the backward
            // run from a post-tail anchor equals the whole day.
            let query = AmbientStorage.segmentsBackwardFromAnchor(
                anchor: anchor, timeZone: jst, sessionsRoot: root)
            if poll.count != expected || query.count != expected {
                lock.lock(); mismatches.add("i=\(i) poll=\(poll.count) query=\(query.count) exp=\(expected)"); lock.unlock()
            }
        }
        XCTAssertEqual(mismatches.count, 0, "parallel poll+query returned inconsistent counts: \(mismatches)")
    }

    /// Reads during a late write never crash and never return a partial/garbage
    /// count — each read sees either the pre- or the post-write content.
    func testConcurrentReadsDuringLateWriteAreConsistent() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 2; c.hour = 12; c.timeZone = jst
        let day = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(day).timeIntervalSince1970
        let before = (1...100).map { seg("s\($0)", at: dayStart + Double($0)) }
        try writeSession("ctx-late", before, under: root)
        let after = before + (101...150).map { seg("s\($0)", at: dayStart + Double($0)) }

        let bad = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 80) { i in
            if i == 40 {
                try? self.writeSession("ctx-late", after, under: root)  // late append mid-flight
            }
            let got = AmbientStorage.segments(forDay: startOfDayJST(day), timeZone: self.jst, sessionsRoot: root)
            if got.count != 100 && got.count != 150 {
                lock.lock(); bad.add(got.count); lock.unlock()
            }
        }
        XCTAssertEqual(bad.count, 0, "a read during a late write returned a partial count: \(bad)")
    }
}
