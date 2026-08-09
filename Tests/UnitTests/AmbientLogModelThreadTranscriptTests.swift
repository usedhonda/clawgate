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

    /// D45: an explicit selection that reconciles to NO current scene is
    /// EXPLICITLY cleared — UI and query fall back to the SAME full-day scope.
    /// This supersedes the A2 stopgap (hard scope, `segments` empty,
    /// `scopeOverride` still set), which WAS the "visible full day / send 0"
    /// divergence this Wave removes: display fell back to the full day while the
    /// query sent zero. Now both share one scope.
    func testBuildQueryEnvelopeStaleIrreconcilableSelectionClearsToFullDay() throws {
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
        // D21: the pure resolver does not publish; the main-thread commit does.
        let prepared = model.prepareLogQuery(actionId: "slot-0", instruction: "このシーンだけ",
                                             sessionsRoot: root)
        XCTAssertEqual(prepared.envelope.segments.map(\.text), ["real content A", "real content B"],
                       "an irreconcilable stale selection clears to the full day, not an empty send")
        XCTAssertNil(prepared.envelope.scopeOverride, "a cleared selection is automatic (full-day) scope")
        model.commitPreparedLogQuery(prepared) { _, _ in }
        XCTAssertTrue(model.selectedSceneIDs.isEmpty,
                      "commit clears the irreconcilable selection so chip and query agree")
    }

    /// D17: a single giant scene straddling the old 2000 display cap keeps ONE
    /// identity across display and query. Selecting its chip sends the WHOLE
    /// scene as an exact scope — never the "visible on screen but 0 sent" path
    /// that arose when the capped display scene id differed from the uncapped
    /// query scene id.
    func testGiantSceneChipSelectionSendsExactFullScopeNotZero() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 12; c.hour = 12; c.timeZone = jst
        let pastDay = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(pastDay).timeIntervalSince1970
        // 2001 contiguous segments (1s apart, well under the 15m scene gap) => one scene.
        let count = 2001
        let segs = (1...count).map { seg("utterance \($0)", at: dayStart + Double($0)) }
        try writeSession("ctx-giant", segs, under: root)

        // The chip id is the scene id derived from the UNCAPPED day.
        let sceneID = AmbientLogGrouping.scenes(from: segs, timeZone: jst)[0].id
        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(pastDay)
        model.selectedSceneIDs = [sceneID]
        let envelope = model.buildQueryEnvelope(actionId: "slot-0", instruction: "このシーン",
                                                now: Date(), sessionsRoot: root)
        XCTAssertEqual(envelope.segments.count, count,
                       "the whole giant scene is in scope — not truncated, and never 0")
        XCTAssertEqual(envelope.scopeOverride, [sceneID],
                       "the honored explicit scope is the single reconciled scene id")
    }

    /// D45: an earlier backfill segment shifts a scene's first epoch (its id).
    /// A selection holding the OLD id reconciles to the scene's new id — display
    /// and query stay on the same scene, and the chip follows the migrated id.
    func testEarlierBackfillReconcilesStaleSceneIdToNewId() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 13; c.hour = 12; c.timeZone = jst
        let pastDay = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(pastDay).timeIntervalSince1970
        let original = [seg("A", at: dayStart + 100), seg("B", at: dayStart + 110)]
        let oldID = AmbientLogGrouping.scenes(from: original, timeZone: jst)[0].id
        // A backfilled earlier segment (+50, same scene: gap < 900s) shifts the first epoch.
        let backfilled = [seg("pre", at: dayStart + 50)] + original
        try writeSession("ctx-bf", backfilled, under: root)
        let newID = AmbientLogGrouping.scenes(from: backfilled, timeZone: jst)[0].id
        XCTAssertNotEqual(oldID, newID, "precondition: the backfill changed the scene id")

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(pastDay)
        model.selectedSceneIDs = [oldID]
        let prepared = model.prepareLogQuery(actionId: "slot-0", instruction: "このシーン",
                                             sessionsRoot: root)
        XCTAssertEqual(prepared.envelope.segments.map(\.text), ["pre", "A", "B"],
                       "the reconciled scene includes the backfilled earlier segment")
        XCTAssertEqual(prepared.envelope.scopeOverride, [newID], "scope migrated to the new scene id")
        model.commitPreparedLogQuery(prepared) { _, _ in }
        XCTAssertEqual(model.selectedSceneIDs, [newID], "commit publishes the migrated selection")
    }

    /// D21: a query prepared under one selection is CANCELLED at commit if the
    /// owner generation changed (a chip/day change mid-preparation) — no stale
    /// reconcile publish, no stale dispatch. A fresh query dispatches once.
    func testStaleGenerationQueryIsCancelledAtCommit() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 22; c.hour = 12; c.timeZone = jst
        let pastDay = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(pastDay).timeIntervalSince1970
        let a = [seg("A1", at: dayStart + 100)]
        let b = [seg("B1", at: dayStart + 5000)]  // >900s later => a separate scene
        try writeSession("ctx-two", a + b, under: root)
        let sceneA = AmbientLogGrouping.scenes(from: a + b, timeZone: jst)[0].id

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(pastDay)
        model.selectedSceneIDs = [sceneA]
        let prepared = model.prepareLogQuery(actionId: "slot-0", instruction: "A", sessionsRoot: root)

        // A chip change bumps the owner generation, invalidating the in-flight query.
        model.selectScene("some-other-id", toggling: false)

        var dispatched = 0
        let ok = model.commitPreparedLogQuery(prepared) { _, _ in dispatched += 1 }
        XCTAssertFalse(ok, "a stale-generation query must not commit")
        XCTAssertEqual(dispatched, 0, "no stale scope is dispatched")

        // A fresh query under the current selection dispatches exactly once.
        let prepared2 = model.prepareLogQuery(actionId: "slot-0", instruction: "A", sessionsRoot: root)
        var dispatched2 = 0
        model.commitPreparedLogQuery(prepared2) { _, _ in dispatched2 += 1 }
        XCTAssertEqual(dispatched2, 1, "the current query dispatches once")
    }

    /// D21: stop() (view gone) invalidates any in-flight query — its commit fails
    /// the generation check, so no stale scope is dispatched after the view
    /// disappears. (The production path additionally does not rebuild while the
    /// lifecycle is inactive.)
    func testStopInvalidatesInFlightQueryAtCommit() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 22; c.hour = 12; c.timeZone = jst
        let pastDay = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(pastDay).timeIntervalSince1970
        try writeSession("ctx-stop", [seg("A1", at: dayStart + 100)], under: root)

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(pastDay)
        let prepared = model.prepareLogQuery(actionId: "slot-0", instruction: "A", sessionsRoot: root)

        model.stop()  // invalidates the in-flight generation

        var dispatched = 0
        let ok = model.commitPreparedLogQuery(prepared) { _, _ in dispatched += 1 }
        XCTAssertFalse(ok, "an in-flight query prepared before stop() must not commit")
        XCTAssertEqual(dispatched, 0, "no dispatch happens after stop()")
    }

    /// D21 production path (end-to-end, real background queue): a chip change
    /// WHILE an action-click query is being built off-main drops the stale
    /// (old-scope) envelope and rebuilds from the latest snapshot — the old scope
    /// dispatches 0 times, the new scope exactly once. Here the chip change is
    /// "全日" (selectAllScenes), so the rebuilt scope is full-day (automatic /
    /// nil), never the stale explicit sceneA.
    func testChipChangeDuringPreparationRebuildsWithNewScope() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 22; c.hour = 12; c.timeZone = jst
        let pastDay = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(pastDay).timeIntervalSince1970
        let a = [seg("A1", at: dayStart + 100)]
        let b = [seg("B1", at: dayStart + 5000)]  // >900s later => a separate scene
        try writeSession("ctx-two", a + b, under: root)
        let sceneA = AmbientLogGrouping.scenes(from: a + b, timeZone: jst)[0].id

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(pastDay)
        model.selectedSceneIDs = [sceneA]

        let exp = expectation(description: "rebuilt query dispatches")
        var dispatchedScopes: [[String]?] = []
        model.startLogQuery(actionId: "slot-0", instruction: "A", sessionsRoot: root) { envelope, _ in
            dispatchedScopes.append(envelope.scopeOverride)
            exp.fulfill()
        }
        // Synchronously (before any background commit can run) change the chip to
        // "全日": the in-flight query prepared under sceneA is now stale.
        model.selectAllScenes()

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(dispatchedScopes.count, 1,
                       "exactly one dispatch — the rebuilt query, not the stale one")
        XCTAssertNil(dispatchedScopes.first ?? nil,
                     "the rebuilt query carries the new full-day scope")
        XCTAssertNotEqual(dispatchedScopes.first ?? nil, [sceneA],
                          "the stale explicit sceneA scope is never dispatched")
        XCTAssertFalse(model.isPreparingLogQuery, "preparing clears once the query resolves")
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

    // MARK: - D20 cross-day backward context (automatic scope)

    /// D20: a conversation whose two turns straddle midnight with a <15m gap is
    /// ONE context — the automatic scope crosses the calendar boundary and
    /// includes the previous day's tail.
    func testAutomaticScopeCrossesMidnightForOneContiguousMeeting() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 15; c.timeZone = jst
        let day = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(day).timeIntervalSince1970
        try writeSession("ctx-mid", [
            seg("前日の続き", at: dayStart - 5 * 60),      // 23:55 (previous day)
            seg("日付をまたいで継続", at: dayStart + 5 * 60), // 00:05 (selected day)
        ], under: root)

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(day)
        let env = model.buildQueryEnvelope(actionId: "free", instruction: "まとめて",
                                           now: Date(), sessionsRoot: root)
        XCTAssertEqual(env.segments.map(\.text), ["前日の続き", "日付をまたいで継続"],
                       "a <15m gap across midnight is one conversation — both days included")
    }

    /// D20: retrieval does NOT stop at a gap — it INCLUDES both sides, in order,
    /// and leaves the boundary decision to the model's automaticBackward trim.
    /// (Excluding the prior meeting is the model's job, not retrieval's — a gap
    /// alone is not a scene change.)
    func testAutomaticScopeIncludesBothSidesOfAHighGapForModelToTrim() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 16; c.timeZone = jst
        let day = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(day).timeIntervalSince1970
        try writeSession("ctx-brk", [
            seg("前日の別会議", at: dayStart - 30 * 60),    // 23:30 (previous day)
            seg("今日の新しい会議", at: dayStart + 5 * 60),  // 00:05 (selected day)
        ], under: root)

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(day)
        let env = model.buildQueryEnvelope(actionId: "free", instruction: "まとめて",
                                           now: Date(), sessionsRoot: root)
        XCTAssertEqual(env.segments.map(\.text), ["前日の別会議", "今日の新しい会議"],
                       "retrieval includes both sides of the gap, ordered; exclusion is the model's job")
        XCTAssertTrue(env.retrievalComplete, "a boundary exists within the window — retrieval is complete")
    }

    /// D20: a same-day lunch gap must not drop the morning — a mere time gap is
    /// not a scene change; retrieval includes the whole day's history.
    func testAutomaticScopeKeepsMorningAcrossALunchGap() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 18; c.hour = 12; c.timeZone = jst
        let day = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(day).timeIntervalSince1970
        try writeSession("ctx-lunch", [
            seg("朝会", at: dayStart + 10 * 3600),    // 10:00
            seg("午後MTG", at: dayStart + 14 * 3600),  // 14:00 (4h lunch gap)
        ], under: root)

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(day)
        let env = model.buildQueryEnvelope(actionId: "free", instruction: "今日を全部",
                                           now: Date(), sessionsRoot: root)
        XCTAssertEqual(env.segments.map(\.text), ["朝会", "午後MTG"],
                       "a lunch gap does not permanently drop the morning from retrieval")
    }

    /// D20/D16 sanity cap: retrieval is conservatively INCOMPLETE whenever any
    /// retained data older than the cap exists. Storage cannot prove a gap is a
    /// semantic boundary, so a gap inside the window does NOT make it complete —
    /// only a window with no older retained data at all is complete.
    func testRetrievalReachedCapWheneverOlderDataExistsPastCap() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let base = Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970
        let anchor = Date(timeIntervalSince1970: base)
        // Every 5 min from 3h before the anchor to well past a 1h cap.
        var segs: [TranscriptSegment] = []
        var t = base - 3 * 3600
        while t < base { segs.append(seg("u\(Int(t))", at: t)); t += 300 }
        try writeSession("ctx-cap", segs, under: root)

        let capped = AmbientStorage.segmentsBackwardFromAnchor(
            anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertTrue(capped.reachedCap,
                      "retained data older than the 1h cap makes retrieval incomplete")

        // A >15m gap INSIDE the 1h window (skip [base-40m, base-20m)) does NOT
        // make it complete: older data still exists past the cap, and a gap is
        // not a boundary the storage layer is allowed to trust.
        var withBoundary: [TranscriptSegment] = []
        var t2 = base - 3 * 3600
        while t2 < base {
            if t2 >= base - 2400 && t2 < base - 1200 { t2 += 300; continue }
            withBoundary.append(seg("v\(Int(t2))", at: t2)); t2 += 300
        }
        try writeSession("ctx-cap", withBoundary, under: root)
        let stillIncomplete = AmbientStorage.segmentsBackwardFromAnchor(
            anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertTrue(stillIncomplete.reachedCap,
                      "a gap inside the window is not a boundary — older pre-cap data still means incomplete")

        // Only data entirely within the window (nothing older than the cap) is
        // complete.
        var withinCapOnly: [TranscriptSegment] = []
        var t3 = base - 1800  // 30 min before anchor, all inside the 1h cap
        while t3 < base { withinCapOnly.append(seg("w\(Int(t3))", at: t3)); t3 += 300 }
        try writeSession("ctx-cap", withinCapOnly, under: root)
        let complete = AmbientStorage.segmentsBackwardFromAnchor(
            anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertFalse(complete.reachedCap,
                       "no retained data older than the cap — retrieval is complete")
    }

    /// D20: the no-decode extension — a session file last written before the cap
    /// (its content therefore entirely pre-cap) marks retrieval incomplete even
    /// when it falls OUTSIDE the 3-day decode scan window, so old retained
    /// archives are never silently treated as absent.
    func testRetrievalReachedCapFromPreCapSessionFileOutsideScanWindow() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let base = Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970
        let anchor = Date(timeIntervalSince1970: base)
        let capEpoch = base - 3600  // 1h cap

        // A recent in-window session (so the window is non-empty and, on its own,
        // complete).
        var recent: [TranscriptSegment] = []
        var t = base - 1800
        while t < base { recent.append(seg("r\(Int(t))", at: t)); t += 300 }
        try writeSession("ctx-recent", recent, under: root)
        let beforeArchive = AmbientStorage.segmentsBackwardFromAnchor(
            anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertFalse(beforeArchive.reachedCap, "recent in-window data alone is complete")

        // An archive whose data sits days before the scan window AND whose file
        // was last written before the cap — undetectable by the decode scan, but
        // its stale mtime proves pre-cap history exists.
        try writeSession("ctx-archive", [seg("old", at: base - 6 * 86400)], under: root)
        let archiveRaw = root.appendingPathComponent("ctx-archive/transcripts/raw.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: capEpoch - 1000)],
            ofItemAtPath: archiveRaw.path)

        let withArchive = AmbientStorage.segmentsBackwardFromAnchor(
            anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertTrue(withArchive.reachedCap,
                      "a pre-cap session file outside the scan window still marks retrieval incomplete")
    }

    /// D20: midnight alone never splits a contiguous run.
    func testAutomaticScopeDoesNotSplitAtPlainMidnight() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 17; c.timeZone = jst
        let day = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(day).timeIntervalSince1970
        try writeSession("ctx-plain", [
            seg("23時58分", at: dayStart - 2 * 60),
            seg("0時01分", at: dayStart + 1 * 60),
            seg("0時04分", at: dayStart + 4 * 60),
        ], under: root)

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(day)
        let env = model.buildQueryEnvelope(actionId: "free", instruction: "まとめて",
                                           now: Date(), sessionsRoot: root)
        XCTAssertEqual(env.segments.map(\.text), ["23時58分", "0時01分", "0時04分"],
                       "midnight alone never splits a contiguous run")
    }
}
