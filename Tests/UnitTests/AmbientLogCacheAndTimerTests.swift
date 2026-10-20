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

    /// D38: a same-second, same-size rewrite (content corrected without changing
    /// the byte count) still changes the fingerprint — the mod-time is kept at
    /// full sub-second precision, so whole-second truncation cannot hide it.
    func testDayFingerprintDetectsSameSecondSameSizeRewrite() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 6; c.hour = 12; c.timeZone = jst
        let day = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(day).timeIntervalSince1970
        let raw = root.appendingPathComponent("ctx-rw/transcripts/raw.jsonl")
        let fm = FileManager.default

        // Same byte count, different content.
        try writeSession("ctx-rw", [seg("AAAA", at: dayStart + 10)], under: root)
        let sizeBefore = (try fm.attributesOfItem(atPath: raw.path)[.size] as? NSNumber)!.uint64Value
        // Pin the mtime to a whole second (sub-second .25) inside the day.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: dayStart + 100.25)],
                             ofItemAtPath: raw.path)
        let fp1 = AmbientStorage.dayFingerprint(forDay: startOfDayJST(day), timeZone: jst, sessionsRoot: root)

        // Rewrite same-size, then pin to the SAME whole second (different sub-second).
        try writeSession("ctx-rw", [seg("BBBB", at: dayStart + 10)], under: root)
        let sizeAfter = (try fm.attributesOfItem(atPath: raw.path)[.size] as? NSNumber)!.uint64Value
        XCTAssertEqual(sizeBefore, sizeAfter, "the rewrite is same-size by construction")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: dayStart + 100.75)],
                             ofItemAtPath: raw.path)
        let fp2 = AmbientStorage.dayFingerprint(forDay: startOfDayJST(day), timeZone: jst, sessionsRoot: root)

        XCTAssertNotEqual(fp1, fp2,
                          "a same-second same-size rewrite still changes the fingerprint (sub-second mtime)")
    }

    // MARK: - D92 poll timer idempotency

    func testStartIsIdempotentKeepingASingleTimer() {
        let model = AmbientLogModel()
        model.sessionsRootOverrideForTesting = makeRoot()
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

    /// D152: a duplicate start() (e.g. a repeated onAppear) must not re-enqueue a
    /// heavy load() — the timer-idempotency guard now runs BEFORE load(), so
    /// exactly one load happens per polling lifecycle.
    func testDuplicateStartDoesNotReEnqueueLoad() {
        let model = AmbientLogModel()
        model.sessionsRootOverrideForTesting = makeRoot()
        model.start()
        model.start()
        model.start()
        XCTAssertEqual(model.loadCallCountForTesting, 1,
                       "duplicate start() while already polling must not re-scan storage")
        model.stop()

        // A start() after stop() is a fresh lifecycle and loads once more.
        model.start()
        XCTAssertEqual(model.loadCallCountForTesting, 2, "start after stop loads once for the new lifecycle")
        model.stop()
    }

    func testDisplayRejectsOldSelectionAndCoalescesBeforeReusingTodaysSource() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = startOfDayJST(Date())
        let start = day.timeIntervalSince1970
        let first = seg("first scene", at: start + 10)
        let second = seg("second scene", at: start + 2000)
        try writeSession("ctx-display-fixture", [first, second], under: root)
        let model = AmbientLogModel(zoneProvider: { self.jst })
        model.sessionsRootOverrideForTesting = root
        defer { model.stop() }
        let firstID = String(Int(start + 10))
        let secondID = String(Int(start + 2000))
        let built = expectation(description: "old snapshot built before selection changes")
        let released = DispatchSemaphore(value: 0)
        defer { released.signal() }
        let finished = expectation(description: "old and latest snapshots finish")
        finished.expectedFulfillmentCount = 2
        let readsLock = NSLock()
        var reads = 0
        var applied: [Bool] = []
        model.displaySourceReadForTesting = {
            readsLock.lock()
            reads += 1
            readsLock.unlock()
        }
        model.displaySnapshotDidBuildForTesting = {
            built.fulfill()
            _ = released.wait(timeout: .now() + 5)
        }
        model.displayLoadDidFinishForTesting = { didApply in
            applied.append(didApply)
            XCTAssertEqual(model.selectedSceneIDs, [secondID])
            finished.fulfill()
        }
        model.selectScene(firstID, toggling: false)
        wait(for: [built], timeout: 3)
        model.displaySnapshotDidBuildForTesting = nil
        for _ in 0..<20 { model.selectScene(secondID, toggling: false) }
        XCTAssertTrue(model.displayHasPendingLoadForTesting)
        released.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(applied, [false, true])
        XCTAssertEqual(model.blocks.map(\.text), ["second scene"])
        XCTAssertFalse(model.displayHasPendingLoadForTesting)
        readsLock.lock()
        let readsBeforePoll = reads
        readsLock.unlock()
        let revision = model.transcriptRevision
        let unchanged = expectation(description: "unchanged display reuses source")
        model.displayLoadDidFinishForTesting = { didApply in
            XCTAssertFalse(didApply)
            unchanged.fulfill()
        }
        model.selectScene(secondID, toggling: false)
        wait(for: [unchanged], timeout: 3)
        readsLock.lock()
        XCTAssertEqual(reads, readsBeforePoll)
        readsLock.unlock()
        XCTAssertEqual(model.transcriptRevision, revision)
        model.displayLoadDidFinishForTesting = nil
    }

    func testDayRoundTripRejectsAnOldMatchingDisplayInput() throws {
        try assertOldDisplayRejected { model in
            model.moveDay(by: -1)
            model.moveDay(by: 1)
        }
    }

    func testFontRoundTripRejectsAnOldMatchingDisplayInput() throws {
        try assertOldDisplayRejected { model in
            let original = model.fontSize
            model.setDisplayFontSizeForTesting(original > 15 ? original - 1 : original + 1)
            model.setDisplayFontSizeForTesting(original)
        }
    }

    func testStopRejectsAnInFlightDisplay() throws {
        try assertOldDisplayRejected(stopped: true) { $0.stop() }
    }

    private func assertOldDisplayRejected(stopped: Bool = false, mutate: (AmbientLogModel) -> Void) throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = startOfDayJST(Date())
        try writeSession("ctx-generation-fixture", [seg("fixture", at: day.timeIntervalSince1970 + 10)], under: root)
        let model = AmbientLogModel(zoneProvider: { self.jst })
        model.sessionsRootOverrideForTesting = root
        defer { model.stop() }
        let built = expectation(description: "old display built")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.displaySnapshotDidBuildForTesting = {
            built.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        var applied: [Bool] = []
        let finished = expectation(description: "display results returned")
        finished.expectedFulfillmentCount = stopped ? 1 : 2
        model.displayLoadDidFinishForTesting = { value in
            applied.append(value)
            finished.fulfill()
        }
        model.selectAllScenes()
        wait(for: [built], timeout: 3)
        model.displaySnapshotDidBuildForTesting = nil
        mutate(model)
        release.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(applied, stopped ? [false] : [false, true])
        XCTAssertFalse(model.displayHasPendingLoadForTesting)
        XCTAssertEqual(model.blocks.map(\.text), stopped ? [] : ["fixture"])
    }
}
