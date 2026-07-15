import XCTest
import Combine
@testable import ClawGate

/// Reproduces the Pet Log "1 update behind" regression: `.onReceive(model.$logReplies)`
/// discarded the emitted value and re-read `model.logReplies` inside the callback.
/// Combine's `@Published` publisher fires on `willSet` — before the property is
/// actually updated — so that re-read observes the PREVIOUS array, one publish
/// behind the response that just arrived.
final class AmbientLogModelThreadTranscriptTests: XCTestCase {
    private var originalLogStoreDir = ""

    override func setUp() {
        super.setUp()
        // Defensive isolation: these tests touch PetModel(), which must never
        // let an incidental PetLogStore.save() reach the user's real
        // ~/.clawgate/logs/log.json. See PetModelDisconnectRoutingTests.swift
        // for the incident this guards against (2026-07-14). `dir` is a
        // process-global static: hold the shared semaphore for the entire
        // setUp...tearDown lifetime so a parallel test in another class
        // can't race this override.
        PetLogStore.testIsolationSemaphore.wait()
        originalLogStoreDir = PetLogStore.dir
        PetLogStore.dir = NSTemporaryDirectory() + "clawgate-test-logs-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: PetLogStore.dir)
        PetLogStore.dir = originalLogStoreDir
        PetLogStore.testIsolationSemaphore.signal()
        super.tearDown()
    }

    /// Documents the exact Combine timing footgun: reading the `@Published`
    /// property from inside its own sink is stale; the sink's emitted
    /// parameter is not.
    func testPublishedPropertyIsStaleWhenReReadInsideItsOwnSink() {
        let model = PetModel()
        var viaEmittedParam: [NotificationEntry] = []
        var viaStalePropertyReread: [NotificationEntry] = []
        let cancellable = model.$logReplies.dropFirst().sink { entries in
            viaEmittedParam = entries
            viaStalePropertyReread = model.logReplies
        }

        model.logReplies.append(NotificationEntry(id: "1", text: "answer", source: "log", timestamp: Date()))

        XCTAssertEqual(viaEmittedParam.count, 1, "the sink's emitted value already contains the new entry")
        XCTAssertEqual(viaStalePropertyReread.count, 0, "re-reading the published property inside its own sink is one publish behind — this was the root cause")
        cancellable.cancel()
    }

    /// The fix passes the emitted array straight through — verify the consumer
    /// (AmbientLogModel.updateThreadTranscript) renders a newly-appended
    /// response into the transcript in a single call, with no second publish
    /// needed to "catch up".
    func testUpdateThreadTranscriptReflectsResponseInSinglePublish() {
        let model = AmbientLogModel()
        let question = NotificationEntry(id: "u1", text: "質問まとめ", source: "log_user", timestamp: Date())
        let answer = NotificationEntry(id: "a1", text: "これが06:05の回答です", source: "log", timestamp: Date())

        model.updateThreadTranscript(entries: [question])
        let revisionAfterQuestion = model.threadTranscriptRevision
        XCTAssertFalse(model.threadTranscript.string.contains(answer.text))

        // Single call carrying the full post-append array — exactly what the
        // fixed `.onReceive(model.$logReplies) { entries in ... }` now passes.
        model.updateThreadTranscript(entries: [question, answer])

        XCTAssertTrue(model.threadTranscript.string.contains(answer.text), "the response must appear after a single update call")
        XCTAssertGreaterThan(model.threadTranscriptRevision, revisionAfterQuestion)
    }

    /// Static guard: the stale-read pattern must not be reintroduced.
    func testOnReceiveLogRepliesDoesNotDiscardEmittedValue() throws {
        let path = "\(sourceRoot())/ClawGate/UI/Pet/AmbientLogPetView.swift"
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(
            source.contains(".onReceive(model.$logReplies) { _ in"),
            "the .onReceive callback must consume its emitted value, not discard it and re-read model.logReplies (stale by one publish)"
        )
    }

    private func sourceRoot() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    // MARK: - buildQueryEnvelope: full-day history, hard scope, anchor cutoff

    private let jst = TimeZone(identifier: "Asia/Tokyo")!

    private func makeTempSessionsRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawgate-envelope-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSession(_ id: String, _ segs: [TranscriptSegment], under root: URL) throws {
        let dir = root
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        let lines = try segs.map { String(data: try enc.encode($0), encoding: .utf8)! }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: dir.appendingPathComponent("raw.jsonl"))
    }

    private func seg(_ text: String, at capturedAt: Double, speaker: String? = nil) -> TranscriptSegment {
        var s = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: text)
        s.capturedAt = capturedAt
        s.speaker = speaker
        return s
    }

    private func startOfDayJST(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jst
        return cal.startOfDay(for: date)
    }

    /// The query envelope reads the FULL raw day — it must not inherit the
    /// display path's 2000-segment (or any fixed) cap.
    func testBuildQueryEnvelopeIsNotCappedAt2000Segments() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A fixed past day so the anchor is that day's coverage tail (not "now").
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 10; c.hour = 12; c.timeZone = jst
        let pastDay = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(pastDay).timeIntervalSince1970

        let count = 2001
        let segs = (1...count).map { seg("utterance \($0)", at: dayStart + Double($0)) }
        try writeSession("ctx-big", segs, under: root)

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(pastDay)
        let envelope = model.buildQueryEnvelope(actionId: "free", instruction: "全部まとめて",
                                                now: Date(), sessionsRoot: root)
        XCTAssertGreaterThan(envelope.segments.count, 2000)
        XCTAssertEqual(envelope.segments.count, count,
                       "the envelope must carry the true full-day count, not a clamped 2000")
    }

    /// A stale/non-matching explicit scene selection is a HARD scope: no silent
    /// fallback to the full day — segments stays empty, scopeOverride reflects
    /// the (unmatched) selection.
    func testBuildQueryEnvelopeStaleSceneSelectionYieldsEmptyNotFullDay() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 11; c.hour = 12; c.timeZone = jst
        let pastDay = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(pastDay).timeIntervalSince1970
        try writeSession("ctx-day", [
            seg("real content A", at: dayStart + 10),
            seg("real content B", at: dayStart + 20),
        ], under: root)

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(pastDay)
        model.selectedSceneIDs = ["stale-scene-id-that-does-not-exist"]
        let envelope = model.buildQueryEnvelope(actionId: "slot-0", instruction: "このシーンだけ",
                                                now: Date(), sessionsRoot: root)
        XCTAssertTrue(envelope.segments.isEmpty,
                      "no scene matched the explicit selection — must not fall back to the full day")
        XCTAssertEqual(envelope.scopeOverride, ["stale-scene-id-that-does-not-exist"],
                       "the honored (unmatched) scope must still be reported")
    }

    /// Same-day query: a segment at/after the anchor instant is excluded.
    func testBuildQueryEnvelopeExcludesSegmentsAtOrAfterAnchor() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let todayStart = startOfDayJST(Date())
        let now = todayStart.addingTimeInterval(12 * 3600) // noon today JST
        let nowEpoch = now.timeIntervalSince1970
        try writeSession("ctx-today", [
            seg("before anchor", at: nowEpoch - 3600),
            seg("at anchor", at: nowEpoch),
            seg("after anchor", at: nowEpoch + 3600),
        ], under: root)

        let model = AmbientLogModel()
        model.selectedDay = todayStart
        let envelope = model.buildQueryEnvelope(actionId: "free", instruction: "今の状況",
                                                now: now, sessionsRoot: root)
        let texts = envelope.segments.map(\.text)
        XCTAssertEqual(texts, ["before anchor"],
                       "only segments strictly before the anchor survive the same-day cutoff")
    }
}
