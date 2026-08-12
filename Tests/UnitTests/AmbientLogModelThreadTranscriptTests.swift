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

    /// The result pane consumes the emitted array directly, hides the persisted
    /// request/audit entry, and renders the latest output in one publish.
    func testUpdateActionResultReflectsOnlyResponseInSinglePublish() {
        let model = AmbientLogModel()
        let question = NotificationEntry(id: "u1", text: "質問まとめ", source: "log_user", timestamp: Date())
        let answer = NotificationEntry(id: "a1", text: "これが06:05の回答です", source: "log", timestamp: Date())

        model.updateActionResult(entries: [question])
        let revisionAfterQuestion = model.actionResultRevision
        XCTAssertTrue(model.actionResult.string.isEmpty, "a command is audit data, not a chat bubble")

        // Single call carrying the full post-append array — exactly what the
        // fixed `.onReceive(model.$logReplies) { entries in ... }` now passes.
        model.updateActionResult(entries: [question, answer])

        XCTAssertEqual(model.actionResult.string, answer.text)
        XCTAssertFalse(model.actionResult.string.contains(question.text))
        XCTAssertGreaterThan(model.actionResultRevision, revisionAfterQuestion)
    }

    func testActionResultProjectsOnlyLatestCommandOutput() {
        let entries = [
            NotificationEntry(id: "u1", text: "最初の指示", source: "log_user", timestamp: Date(timeIntervalSince1970: 1)),
            NotificationEntry(id: "a1", text: "古い結果", source: "log", timestamp: Date(timeIntervalSince1970: 2)),
            NotificationEntry(id: "u2", text: "要点", source: "log_user", timestamp: Date(timeIntervalSince1970: 3)),
            NotificationEntry(id: "a2", text: "最新の結果", source: "log", timestamp: Date(timeIntervalSince1970: 4)),
        ]

        XCTAssertEqual(LogActionResultProjection.latestResult(in: entries)?.id, "a2")
        let model = AmbientLogModel()
        model.updateActionResult(entries: entries)
        XCTAssertEqual(model.actionResult.string, "最新の結果")

        let nextRequest = NotificationEntry(
            id: "u3", text: "TODO", source: "log_user", timestamp: Date(timeIntervalSince1970: 5))
        XCTAssertNil(LogActionResultProjection.latestResult(in: entries + [nextRequest]),
                     "a new command clears the old output while its own result is pending")
    }

    func testLegacyBuiltInSummaryMigratesWithoutOverwritingCustomizedAction() {
        let legacy = LogCustomAction(label: "要点", prompt: """
            この会話ログでは、話者ラベル「ご主人様」はこちら側、「相手」は会話の相手方として扱って。
            単なる要約ではなく、会話の構造を分析して、(1) ご主人様が求めていること、(2) 相手が実際に答えたこと、(3) まだ噛み合っていない点、(4) 次に判断すべき論点、を分けて整理して。
            出力は3〜5個の箇条書き。各項目は短い見出し + 1文の説明にして、相手の発言に依存する要点は「相手曰く」と分かるように書いて。
            """)
        var actions: [LogCustomAction?] = [nil, legacy]
        let migrated = LogCustomActionStore.migrateBuiltInActions(actions)
        XCTAssertEqual(migrated[1], LogCustomActionStore.topicSummaryAction)
        XCTAssertTrue(migrated[1]?.prompt.contains("話題空間") == true)
        XCTAssertTrue(migrated[1]?.prompt.contains("【全体まとめ】") == true)
        XCTAssertFalse(migrated[1]?.prompt.contains("3〜5個") == true)

        let customized = LogCustomAction(label: "要点", prompt: "私専用のまとめ方")
        actions[1] = customized
        XCTAssertEqual(LogCustomActionStore.migrateBuiltInActions(actions)[1], customized)
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

    func testRightPaneIsAnActionResultSurfaceNotAChatThread() throws {
        let path = "\(sourceRoot())/ClawGate/UI/Pet/AmbientLogPetView.swift"
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(source.contains("Text(\"実行結果\")"))
        XCTAssertTrue(source.contains("Button(\"結果をコピー\")"))
        XCTAssertTrue(source.contains("左のボタンまたは入力欄から指示してください"))
        XCTAssertFalse(source.contains("Text(\"ちーとの対話\")"))
        XCTAssertFalse(source.contains("Text(\"まだ会話がありません\")"))
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

    /// D156: an explicit selection that reconciles to NO current scene is NOT
    /// silently widened to the full day within the same click (the old D45
    /// clear-and-auto-expand). Instead the envelope is flagged `staleScopeCleared`
    /// (empty segments, no scope), the commit publishes the clear so the chip
    /// resets, and the action is cancelled downstream. The NEXT click — now with
    /// no selection — uses automatic full-day scope.
    func testBuildQueryEnvelopeStaleIrreconcilableSelectionRefusesNotAutoExpands() throws {
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
        XCTAssertTrue(prepared.envelope.segments.isEmpty,
                      "a stale selection is NOT silently widened to the full day (no auto-expand)")
        XCTAssertTrue(prepared.envelope.staleScopeCleared,
                      "the envelope is flagged so the action is cancelled with a distinct status")
        XCTAssertNil(prepared.envelope.scopeOverride)

        var dispatched = 0
        model.commitPreparedLogQuery(prepared) { _, _ in dispatched += 1 }
        XCTAssertTrue(model.selectedSceneIDs.isEmpty,
                      "commit clears the stale selection so the chip resets for the next click")

        // A fresh query — now with no selection — is the full-day automatic scope.
        model.selectedSceneIDs = []
        let next = model.prepareLogQuery(actionId: "slot-0", instruction: "全部", sessionsRoot: root)
        XCTAssertEqual(next.envelope.segments.map(\.text), ["real content A", "real content B"],
                       "the next click (no selection) uses automatic full-day scope")
        XCTAssertFalse(next.envelope.staleScopeCleared)
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
        model.sessionsRootOverrideForTesting = root
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
        model.sessionsRootOverrideForTesting = root
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

    /// D21 per-action owner: a rapid double-click of the SAME action (no scope
    /// change) dispatches ONLY the latest query — the first is superseded and
    /// dropped (never rebuilt), distinct from the chip-change rebuild path.
    func testRapidDoubleClickDispatchesOnlyLatest() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 22; c.hour = 12; c.timeZone = jst
        let pastDay = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(pastDay).timeIntervalSince1970
        try writeSession("ctx-one", [seg("A", at: dayStart + 100)], under: root)

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(pastDay)

        var dispatched = 0
        model.startLogQuery(actionId: "slot-0", instruction: "1", sessionsRoot: root) { _, _ in dispatched += 1 }
        model.startLogQuery(actionId: "slot-0", instruction: "2", sessionsRoot: root) { _, _ in dispatched += 1 }

        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(dispatched, 1, "a rapid double-click dispatches only the latest query, not both")
        XCTAssertFalse(model.isPreparingLogQuery, "preparing clears once the latest resolves")
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
        XCTAssertFalse(env.retrievalTruncatedBeforeCoverage,
                       "no retained data older than the cap — not truncated")
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

    /// D155: an EMPTY past day must not borrow the previous day's history via a
    /// day-end anchor — the automatic scope is empty (refused downstream), never a
    /// silent cross-day send for a visibly empty day.
    func testEmptyPastDayDoesNotBorrowPreviousDayHistory() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 25; c.timeZone = jst
        let emptyDay = Calendar(identifier: .gregorian).date(from: c)!
        let emptyStart = startOfDayJST(emptyDay).timeIntervalSince1970
        // Data only on the PREVIOUS day (1h before the empty day's start).
        try writeSession("ctx-prev", [seg("前日の会議", at: emptyStart - 3600)], under: root)

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(emptyDay)
        let env = model.buildQueryEnvelope(actionId: "free", instruction: "この日をまとめて", sessionsRoot: root)
        XCTAssertTrue(env.segments.isEmpty,
                      "an empty past day sends nothing — no previous-day history borrowed")
        XCTAssertFalse(env.segments.contains { $0.text == "前日の会議" },
                       "the previous day's text must never leak into an empty day's query")
    }

    /// D153: scanBackward reports `truncatedBeforeCoverage` from capturedAt
    /// (never mtime) — true whenever any retained segment is older than the cap.
    /// The window is exactly the in-`[cap, anchor)` segments, ordered. A pre-cap
    /// segment marks truncation even when the file's mtime is recent (backfilled).
    func testScanBackwardTruncatedFromCapturedAtAndOrderedWindow() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let base = Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970
        let anchor = Date(timeIntervalSince1970: base)

        // (c) only within-cap data -> not truncated; window = those segments.
        var within: [TranscriptSegment] = []
        var t = base - 1800  // 30 min before anchor (inside the 1h cap)
        while t < base { within.append(seg("w\(Int(t))", at: t)); t += 300 }
        try writeSession("ctx-in", within, under: root)
        let s1 = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertFalse(s1.truncatedBeforeCoverage, "no data older than the cap -> not truncated")
        XCTAssertEqual(s1.window.map(\.text), within.map(\.text), "window is the ordered in-cap segments")

        // (a) a pre-cap segment exists -> truncated, EVEN though its file's mtime
        // is recent (written just now). Determined by capturedAt, not mtime.
        try writeSession("ctx-old", [seg("古い", at: base - 3 * 3600)], under: root) // 3h before, < 1h cap
        let s2 = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertTrue(s2.truncatedBeforeCoverage,
                      "a pre-cap capturedAt marks truncation regardless of a recent mtime")
        XCTAssertEqual(s2.window.map(\.text), within.map(\.text),
                       "the pre-cap segment is reported as truncation, not placed in the window")
    }

    /// D153: an OLD file mtime does NOT imply truncation — only capturedAt does.
    /// A session last written long ago but holding only within-cap segments is
    /// not truncated (mtime is a cache hint, never the truncation signal).
    func testScanBackwardOldMtimeWithinCapIsNotTruncated() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let base = Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970
        let anchor = Date(timeIntervalSince1970: base)

        try writeSession("ctx-w", [seg("直近", at: base - 600)], under: root) // 10 min before, in cap
        let raw = root.appendingPathComponent("ctx-w/transcripts/raw.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: base - 10 * 86400)], // stale mtime
            ofItemAtPath: raw.path)

        let scan = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertFalse(scan.truncatedBeforeCoverage,
                       "a stale mtime with only within-cap capturedAt is NOT truncated")
        XCTAssertEqual(scan.window.map(\.text), ["直近"])
    }

    /// D163: an undated real utterance is counted as a source issue — the anchor
    /// cutoff cannot be verified against it, so the query must fail closed rather
    /// than silently drop it. Dated segments still form the window.
    func testScanBackwardCountsMissingTimestamp() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let base = Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970
        let anchor = Date(timeIntervalSince1970: base)

        var undated = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "no timestamp")
        undated.capturedAt = nil
        try writeSession("ctx-x", [seg("A", at: base - 600), seg("B", at: base - 300), undated], under: root)

        let scan = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertEqual(scan.issues.missingTimestampCount, 1, "the undated line is counted as a source issue")
        XCTAssertTrue(scan.hasSourceIssue)
        XCTAssertEqual(scan.window.map(\.text), ["A", "B"], "dated segments still form the window")
    }

    func testScanBackwardIgnoresProvablyOldUndatedRowsAndMissingRawSessions() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var undated = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "legacy")
        undated.capturedAt = nil
        try writeSession("ctx-2098-01-01T00-00-00Z", [undated], under: root)
        try writeSession("ctx-2099-01-01T00-00-00Z", [], under: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ctx-2099-06-01T00-00-00Z"),
            withIntermediateDirectories: true)

        let anchor = ISO8601DateFormatter().date(from: "2100-01-01T00:00:00Z")!
        let scan = AmbientStorage.scanBackward(
            anchor: anchor, sanityCapHours: 48, timeZone: jst, sessionsRoot: root)

        XCTAssertEqual(scan.issues.missingTimestampCount, 0)
        XCTAssertEqual(scan.issues.readFailureCount, 0)
        XCTAssertFalse(scan.hasSourceIssue)
        XCTAssertTrue(scan.truncatedBeforeCoverage)
    }

    /// D159: a malformed transcript line is counted as a decode failure — the
    /// scan reports the source is incomplete rather than silently dropping it.
    func testScanBackwardCountsDecodeFailure() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let base = Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970
        let anchor = Date(timeIntervalSince1970: base)

        try writeSession("ctx-m", [seg("valid", at: base - 600)], under: root)
        let raw = root.appendingPathComponent("ctx-m/transcripts/raw.jsonl")
        let existing = try String(contentsOf: raw, encoding: .utf8)
        try (existing + "{ this is not json\n").write(to: raw, atomically: true, encoding: .utf8)

        let scan = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertEqual(scan.issues.decodeFailureCount, 1, "the malformed line is counted")
        XCTAssertTrue(scan.hasSourceIssue)
        XCTAssertEqual(scan.window.map(\.text), ["valid"], "the valid segment is still returned")
    }

    /// D159: an ABSENT sessions root is "no records" (typed empty), NOT a source
    /// issue — distinct from an unreadable session.
    func testScanBackwardAbsentRootIsNotASourceIssue() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawgate-absent-\(UUID().uuidString)", isDirectory: true)
        let scan = AmbientStorage.scanBackward(anchor: Date(), sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertFalse(scan.hasSourceIssue, "an absent root is empty, not a source issue")
        XCTAssertTrue(scan.window.isEmpty)
    }

    /// A3-02: an EXISTING but unreadable sessions root is a source issue (old
    /// impl folded ENOENT and EACCES into the same "no records" empty).
    func testScanBackwardUnreadableExistingRootIsSourceIssue() throws {
        let root = makeTempSessionsRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try writeSession("ctx-1", [seg("x", at: Date().timeIntervalSince1970 - 600)], under: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)

        let scan = AmbientStorage.scanBackward(anchor: Date(), sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertTrue(scan.issues.rootUnreadable, "an existing unreadable root is flagged (not silent empty)")
        XCTAssertTrue(scan.hasSourceIssue)
    }

    /// A3-03/D177: a fresh ctx whose raw.jsonl has not been written yet is a
    /// normal 0-record session, NOT a read failure (old impl counted the absent
    /// raw as readFailure and refused every action right after startup).
    func testScanBackwardFreshCtxWithoutRawIsNotAFailure() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let base = Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970

        try writeSession("ctx-valid", [seg("valid", at: base - 600)], under: root)
        // A fresh session: transcripts/ exists but raw.jsonl was never written.
        let freshDir = root.appendingPathComponent("ctx-fresh/transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)

        let scan = AmbientStorage.scanBackward(anchor: Date(timeIntervalSince1970: base),
                                               sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertFalse(scan.hasSourceIssue, "a fresh ctx without raw.jsonl is 0 records, not a failure")
        XCTAssertEqual(scan.window.map(\.text), ["valid"], "the valid session still dispatches")
    }

    /// A3-03: an EXISTING raw that cannot be read IS a source issue.
    func testScanBackwardUnreadableExistingRawIsSourceIssue() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let base = Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970

        try writeSession("ctx-x", [seg("x", at: base - 600)], under: root)
        let raw = root.appendingPathComponent("ctx-x/transcripts/raw.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: raw.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: raw.path) }

        let scan = AmbientStorage.scanBackward(anchor: Date(timeIntervalSince1970: base),
                                               sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertGreaterThanOrEqual(scan.issues.readFailureCount, 1, "an unreadable existing raw is an issue")
        XCTAssertTrue(scan.hasSourceIssue)
    }

    /// A3-05: a read failure is NOT cached — after the permission is restored
    /// (mtime/size unchanged, so a cached failure would persist) the next scan
    /// recovers instead of refusing forever.
    func testReadFailureNotCachedRecoversAfterPermissionRestore() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let base = Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970
        let anchor = Date(timeIntervalSince1970: base)

        try writeSession("ctx-r", [seg("v", at: base - 600)], under: root)
        let raw = root.appendingPathComponent("ctx-r/transcripts/raw.jsonl")

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: raw.path)
        let scan1 = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertTrue(scan1.hasSourceIssue, "unreadable raw -> source issue")

        // Restore read permission WITHOUT touching content (mtime/size unchanged).
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: raw.path)
        let scan2 = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertFalse(scan2.hasSourceIssue, "after permission restore the read recovers (failure was not cached)")
        XCTAssertEqual(scan2.window.map(\.text), ["v"], "segments recovered, not stuck on a cached failure")
    }

    /// A3-05/D42: a rewrite that races the decode is retried against the settled
    /// file — the torn (old) snapshot is never cached or returned, and a later
    /// scan serves the settled content (no rollback to the old bytes).
    func testMidDecodeRewriteRetriesAndCachesSettledContentNotTorn() throws {
        let root = makeTempSessionsRoot()
        let rawPath = root.appendingPathComponent("ctx-race/transcripts/raw.jsonl").path
        defer {
            AmbientStorage.removeDecodePauseHookForTesting(rawPath: rawPath)
            try? FileManager.default.removeItem(at: root)
        }
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let base = Calendar(identifier: .gregorian).date(from: c)!.timeIntervalSince1970
        let anchor = Date(timeIntervalSince1970: base)

        try writeSession("ctx-race", [seg("old", at: base - 600)], under: root)   // F1
        // On the first decode only, rewrite the file to F2 (different content+size).
        // The registry already targets this exact canonical raw path, so the hook
        // body only guards reentrancy (`rewrote`).
        var rewrote = false
        AmbientStorage.setDecodePauseHookForTesting(rawPath: rawPath) { [weak self] _ in
            guard let self, !rewrote else { return }
            rewrote = true
            try? self.writeSession("ctx-race",
                                   [seg("new1", at: base - 500), seg("new2", at: base - 400)], under: root)
        }

        let scan = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        AmbientStorage.removeDecodePauseHookForTesting(rawPath: rawPath)
        XCTAssertEqual(scan.window.map(\.text), ["new1", "new2"],
                       "a mid-decode rewrite is retried; the settled F2 is returned, never the torn F1")

        let scan2 = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 1, timeZone: jst, sessionsRoot: root)
        XCTAssertEqual(scan2.window.map(\.text), ["new1", "new2"],
                       "the cache holds the settled F2 — never rolled back to F1")
    }

    // MARK: - A3-25 canonical snapshot / undated provenance bound

    private let utc = TimeZone(identifier: "UTC")!
    private func iso(_ s: String) -> Double {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)!.timeIntervalSince1970
    }
    private func setRawMtime(_ id: String, _ epoch: Double, under root: URL) throws {
        let raw = root.appendingPathComponent("\(id)/transcripts/raw.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: epoch)], ofItemAtPath: raw.path)
    }
    private func undatedSeg(_ text: String) -> TranscriptSegment {
        var s = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: text); s.capturedAt = nil; return s
    }
    private func writePreset(_ id: String, chunkSeconds: Int, under root: URL) throws {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = "{\"chunkSeconds\":\(chunkSeconds),\"preset\":\"default\",\"promptUsed\":false}"
        try Data(json.utf8).write(to: dir.appendingPathComponent("preset.json"))
    }

    /// A3-25: only the two capture-policy values proven by repository history
    /// receive precise margins; missing/unknown metadata fails closed to 63s.
    func testUndatedLowerMarginIsVersionedMapping() throws {
        let session = "ctx-2026-06-09T10-00-00Z"
        let s1Start = iso("2026-06-09T10:00:00Z")
        func lower(preset chunkSeconds: Int?) throws -> Double {
            let root = makeTempSessionsRoot()
            defer { AmbientStorage.clearCanonicalIndexForTesting(); try? FileManager.default.removeItem(at: root) }
            AmbientStorage.clearCanonicalIndexForTesting()
            try writeSession(session, [undatedSeg("u")], under: root)
            if let chunkSeconds { try writePreset(session, chunkSeconds: chunkSeconds, under: root) }
            return AmbientStorage.canonicalSnapshots(sessionsRoot: root).snapshots
                .first { $0.path.contains(session) }!.undatedLower!
        }
        XCTAssertEqual(try lower(preset: 30), s1Start - 33, accuracy: 0.001)
        XCTAssertEqual(try lower(preset: 20), s1Start - 20, accuracy: 0.001)
        XCTAssertEqual(try lower(preset: nil), s1Start - 63, accuracy: 0.001)
        XCTAssertEqual(try lower(preset: 45), s1Start - 63, accuracy: 0.001,
                       "unknown values do not inherit an unproven +3 overlap")
    }

    /// A3-25/D42 point2: a reader whose decode is raced by a newer publish returns
    /// the SETTLED (new) content, never the torn/old snapshot, and the index is
    /// never rolled back to the old bytes.
    func testConcurrentNewerPublishIsNotRolledBack() throws {
        let root = makeTempSessionsRoot()
        let rawPath = root.appendingPathComponent("ctx-2026-06-09T10-00-00Z/transcripts/raw.jsonl").path
        defer {
            AmbientStorage.removeDecodePauseHookForTesting(rawPath: rawPath)
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        let anchor = Date(timeIntervalSince1970: iso("2026-06-09T13:00:00Z"))
        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("old", at: iso("2026-06-09T10:00:00Z"))], under: root)

        var fired = false
        AmbientStorage.setDecodePauseHookForTesting(rawPath: rawPath) { [weak self] _ in
            guard let self, !fired else { return }
            fired = true
            // "B": rewrite to newer content and publish it into the index while
            // "A" is mid-decode of the old bytes.
            try? self.writeSession("ctx-2026-06-09T10-00-00Z", [seg("new", at: iso("2026-06-09T10:30:00Z"))], under: root)
            _ = AmbientStorage.canonicalSnapshots(sessionsRoot: root)
        }
        // "A": resumes after the racing publish; its re-stat retries onto the
        // settled (new) content.
        let aScan = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        AmbientStorage.removeDecodePauseHookForTesting(rawPath: rawPath)
        XCTAssertEqual(aScan.window.map(\.text), ["new"], "A returns the settled newer content, never the torn old snapshot")

        // The index was not rolled back: a cache-served scan is still the new content.
        let cached = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        XCTAssertEqual(cached.window.map(\.text), ["new"], "the index holds the newer content, never rolled back to old")
    }

    /// A3-25/D42 point3 (Cdx): the decode-pause seam is a PATH-SCOPED registry, so
    /// two hooks for the SAME relative raw path under DIFFERENT temp roots coexist.
    /// The old suffix-keyed registry collided on that shared suffix, while exact
    /// canonical paths preserve both registrations without cross-fire.
    func testDecodePauseHooksArePathScopedAndDoNotCrossFire() throws {
        let rootA = makeTempSessionsRoot()
        let rootB = makeTempSessionsRoot()
        let session = "ctx-2026-06-09T10-00-00Z"
        let rawA = rootA.appendingPathComponent("\(session)/transcripts/raw.jsonl").path
        let rawB = rootB.appendingPathComponent("\(session)/transcripts/raw.jsonl").path
        defer {
            AmbientStorage.removeDecodePauseHookForTesting(rawPath: rawA)
            AmbientStorage.removeDecodePauseHookForTesting(rawPath: rawB)
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSession(session, [seg("a", at: iso("2026-06-09T10:00:00Z"))], under: rootA)
        try writeSession(session, [seg("b", at: iso("2026-06-09T10:00:00Z"))], under: rootB)

        // Register A THEN B (B is the later writer — the one that clobbered A under
        // the old single-slot seam). Each hook records which raw path it actually saw.
        var aFiredFor: [String] = []
        var bFiredFor: [String] = []
        AmbientStorage.setDecodePauseHookForTesting(rawPath: rawA) { aFiredFor.append($0) }
        AmbientStorage.setDecodePauseHookForTesting(rawPath: rawB) { bFiredFor.append($0) }

        _ = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-06-09T13:00:00Z")),
            sanityCapHours: 48, timeZone: utc, sessionsRoot: rootA)
        _ = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-06-09T13:00:00Z")),
            sanityCapHours: 48, timeZone: utc, sessionsRoot: rootB)

        XCTAssertEqual(aFiredFor.count, 1, "hook A fires exactly once (old single slot: B clobbers A -> 0)")
        XCTAssertEqual(bFiredFor.count, 1, "hook B fires exactly once")
        XCTAssertEqual(aFiredFor.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       [URL(fileURLWithPath: rawA).resolvingSymlinksInPath().path])
        XCTAssertEqual(bFiredFor.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       [URL(fileURLWithPath: rawB).resolvingSymlinksInPath().path])
    }

    /// A3-25/#7 (D42 point2, ctime in the equality fingerprint): a content rewrite
    /// with the SAME size AND SAME mtime is still re-decoded, never served stale,
    /// because st_ctime advances on every write and cannot be backdated. The old
    /// `size:mtime` fingerprint would collide and return the stale content.
    func testSameSizeSameMtimeButNewCtimeIsReDecodedNotStale() throws {
        let root = makeTempSessionsRoot()
        defer { AmbientStorage.clearCanonicalIndexForTesting(); try? FileManager.default.removeItem(at: root) }
        AmbientStorage.clearCanonicalIndexForTesting()
        let anchor = Date(timeIntervalSince1970: iso("2026-06-09T13:00:00Z"))
        let fixedMtime = iso("2026-06-09T10:05:00Z")
        let at = iso("2026-06-09T10:00:00Z")

        // "old" and "new" are both 3 ASCII chars -> identical serialized raw size.
        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("old", at: at)], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", fixedMtime, under: root)
        let scan1 = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        XCTAssertEqual(scan1.window.map(\.text), ["old"])

        // Rewrite same-size content, then restore the SAME mtime. Size and mtime are
        // now identical to before; only st_ctime advanced (the rewrite + setAttributes
        // bump it). The old (size:mtime)-only fingerprint would collide and serve the
        // stale "old"; the (size:mtime:ctime) fingerprint detects it and re-decodes.
        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("new", at: at)], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", fixedMtime, under: root)
        let scan2 = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        XCTAssertEqual(scan2.window.map(\.text), ["new"],
                       "same size+mtime but a new ctime is re-decoded, never served stale (D42 point2/#7)")
    }

    func testSameMtimeSameSizeConcurrentRewriteSettlesOnNewNotStale() throws {
        let root = makeTempSessionsRoot()
        let rawPath = root.appendingPathComponent("ctx-2026-06-09T10-00-00Z/transcripts/raw.jsonl").path
        defer {
            AmbientStorage.removeDecodePauseHookForTesting(rawPath: rawPath)
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        let anchor = Date(timeIntervalSince1970: iso("2026-06-09T13:00:00Z"))
        let fixedMtime = iso("2026-06-09T10:05:00Z")
        let at = iso("2026-06-09T10:00:00Z")
        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("old", at: at)], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", fixedMtime, under: root)

        var fired = false
        AmbientStorage.setDecodePauseHookForTesting(rawPath: rawPath) { [weak self] _ in
            guard let self, !fired else { return }
            fired = true
            try? self.writeSession("ctx-2026-06-09T10-00-00Z", [seg("new", at: at)], under: root)
            try? self.setRawMtime("ctx-2026-06-09T10-00-00Z", fixedMtime, under: root)
            _ = AmbientStorage.canonicalSnapshots(sessionsRoot: root)
        }
        let first = AmbientStorage.scanBackward(
            anchor: anchor, sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        AmbientStorage.removeDecodePauseHookForTesting(rawPath: rawPath)
        XCTAssertEqual(first.window.map(\.text), ["new"])
        XCTAssertEqual(AmbientStorage.scanBackward(
            anchor: anchor, sanityCapHours: 48, timeZone: utc, sessionsRoot: root).window.map(\.text), ["new"])
    }

    func testRewriteAfterDecodeDoesNotPoisonSnapshotWithNewFingerprint() throws {
        let root = makeTempSessionsRoot()
        let rawPath = root.appendingPathComponent("ctx-2026-06-09T10-00-00Z/transcripts/raw.jsonl").path
        defer {
            AmbientStorage.removeSnapshotPauseHookForTesting(rawPath: rawPath)
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        let anchor = Date(timeIntervalSince1970: iso("2026-06-09T13:00:00Z"))
        let fixedMtime = iso("2026-06-09T10:05:00Z")
        let at = iso("2026-06-09T10:00:00Z")
        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("old", at: at)], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", fixedMtime, under: root)

        var fired = false
        AmbientStorage.setSnapshotPauseHookForTesting(rawPath: rawPath) { [weak self] _ in
            guard let self, !fired else { return }
            fired = true
            try? self.writeSession("ctx-2026-06-09T10-00-00Z", [seg("new", at: at)], under: root)
            try? self.setRawMtime("ctx-2026-06-09T10-00-00Z", fixedMtime, under: root)
        }
        _ = AmbientStorage.scanBackward(
            anchor: anchor, sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        AmbientStorage.removeSnapshotPauseHookForTesting(rawPath: rawPath)

        XCTAssertEqual(AmbientStorage.scanBackward(
            anchor: anchor, sanityCapHours: 48, timeZone: utc, sessionsRoot: root).window.map(\.text), ["new"],
            "a rewrite after decode is not hidden by labeling old bytes with the newer fingerprint")
    }

    func testFingerprintCtimeUnavailableFallsBackToContentIdentity() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.fingerprintCtimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        AmbientStorage.fingerprintCtimeProviderForTesting = { _ in nil }
        let anchor = Date(timeIntervalSince1970: iso("2026-06-09T13:00:00Z"))
        let fixedMtime = iso("2026-06-09T10:05:00Z")
        let at = iso("2026-06-09T10:00:00Z")
        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("old", at: at)], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", fixedMtime, under: root)
        let firstFingerprint = AmbientStorage.dayFingerprint(
            forDay: Date(timeIntervalSince1970: at), timeZone: utc, sessionsRoot: root)

        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("new", at: at)], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", fixedMtime, under: root)
        let second = AmbientStorage.scanBackward(
            anchor: anchor, sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        let secondFingerprint = AmbientStorage.dayFingerprint(
            forDay: Date(timeIntervalSince1970: at), timeZone: utc, sessionsRoot: root)

        XCTAssertEqual(second.window.map(\.text), ["new"])
        XCTAssertNotEqual(firstFingerprint, secondFingerprint,
                          "without ctime, same-size/same-mtime content still invalidates via settled SHA")
    }

    /// A3-25/#4: a stable (same-fingerprint) file is decoded exactly ONCE across
    /// repeated scans — the canonical index reuses the snapshot (no rebuild) and the
    /// session cache dedups the decode below it.
    func testStableFileFingerprintDecodesOncePerProcess() throws {
        let root = makeTempSessionsRoot()
        defer { AmbientStorage.clearCanonicalIndexForTesting(); try? FileManager.default.removeItem(at: root) }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("x", at: iso("2026-06-09T10:00:00Z"))], under: root)
        let anchor = Date(timeIntervalSince1970: iso("2026-06-09T13:00:00Z"))

        AmbientStorage.decodeCountForTesting = 0
        for _ in 0..<3 {
            _ = AmbientStorage.scanBackward(anchor: anchor, sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        }
        XCTAssertEqual(AmbientStorage.decodeCountForTesting, 1,
                       "a stable same-fingerprint file is decoded exactly once across repeated scans")
    }

    /// A3-25 (P0 848件): an undated file's provenance bound only makes a query a
    /// source issue when it INTERSECTS the window. A June session's undated
    /// records (bounded by its next session) can't touch an Aug automatic window,
    /// so the query is NOT refused (a GLOBAL count would refuse every query); a
    /// query on the undated file's OWN day IS refused.
    func testUndatedFileBoundOnlyIssuesWhenIntersectsWindow() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        // st_ctime can't be backdated on disk (setAttributes sets it to NOW), so a
        // June-only fixture would read a now-ctime and become non-deterministic.
        // Inject a June ctime (<= the June-12 next SID) to make the bound the
        // genuinely-consistent one this test is about.
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z")) }

        // S1 (June 9 10:00) undated-only; S2 (June 9 12:00) dated -> S1 has a next
        // session bound. Backdate mtimes to June (mtime <= next SID => deterministic).
        try writeSession("ctx-2026-06-09T10-00-00Z", [undatedSeg("u1"), undatedSeg("u2")], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T10:30:00Z"), under: root)
        try writeSession("ctx-2026-06-09T12-00-00Z", [seg("dated", at: iso("2026-06-09T12:05:00Z"))], under: root)
        try setRawMtime("ctx-2026-06-09T12-00-00Z", iso("2026-06-09T12:10:00Z"), under: root)

        let augScan = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-08-09T12:00:00Z")),
            sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        XCTAssertFalse(augScan.hasSourceIssue,
                       "a June undated bound can't touch an Aug window -> not an issue (else all 848 refuse)")

        let juneDay = AmbientStorage.segmentsForDayWithIssues(
            forDay: Date(timeIntervalSince1970: iso("2026-06-09T10:00:00Z")), timeZone: utc, sessionsRoot: root)
        XCTAssertTrue(juneDay.issues.hasIssue, "the undated file's bound intersects its own day -> source issue")
    }

    /// A3-25/D151: an unrelated TODAY-session append (capturedAt today) must NOT
    /// change a PAST day's fingerprint — relevance is by capturedAt [min,max], not
    /// mtime, so a viewed past day is not re-scanned every poll during live capture.
    func testTodayAppendDoesNotChurnPastDayFingerprint() throws {
        let root = makeTempSessionsRoot()
        defer { AmbientStorage.clearCanonicalIndexForTesting(); try? FileManager.default.removeItem(at: root) }
        AmbientStorage.clearCanonicalIndexForTesting()
        let pastDay = Date(timeIntervalSince1970: iso("2026-06-09T00:00:00Z"))

        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("past", at: iso("2026-06-09T10:00:00Z"))], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T10:05:00Z"), under: root)
        let fp1 = AmbientStorage.dayFingerprint(forDay: pastDay, timeZone: utc, sessionsRoot: root)

        try writeSession("ctx-2026-08-09T10-00-00Z", [seg("today", at: iso("2026-08-09T10:00:00Z"))], under: root)
        let fp2 = AmbientStorage.dayFingerprint(forDay: pastDay, timeZone: utc, sessionsRoot: root)

        XCTAssertEqual(fp1, fp2, "an unrelated today-session append must not change a past day's fingerprint (D151)")
    }

    /// A3-25: the in-memory index is not durable — a rebuild (as after a restart)
    /// yields the same segments and issues.
    func testCanonicalIndexRebuildYieldsSameResult() throws {
        let root = makeTempSessionsRoot()
        defer { AmbientStorage.clearCanonicalIndexForTesting(); try? FileManager.default.removeItem(at: root) }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("a", at: iso("2026-06-09T10:00:00Z"))], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T10:05:00Z"), under: root)
        let day = Date(timeIntervalSince1970: iso("2026-06-09T00:00:00Z"))

        let r1 = AmbientStorage.segmentsForDayWithIssues(forDay: day, timeZone: utc, sessionsRoot: root)
        let fp1 = AmbientStorage.dayFingerprint(forDay: day, timeZone: utc, sessionsRoot: root)
        AmbientStorage.clearCanonicalIndexForTesting()  // simulate a restart
        let r2 = AmbientStorage.segmentsForDayWithIssues(forDay: day, timeZone: utc, sessionsRoot: root)
        let fp2 = AmbientStorage.dayFingerprint(forDay: day, timeZone: utc, sessionsRoot: root)

        XCTAssertEqual(r1.segments.map(\.text), r2.segments.map(\.text), "rebuilt index -> same segments")
        XCTAssertEqual(r1.issues, r2.issues, "rebuilt index -> same issues")
        // #3: the rebuild (as after a restart) also yields the SAME fingerprint —
        // the (size, mtime, ctime) composition is stable for an unchanged file.
        XCTAssertEqual(fp1, fp2, "rebuilt index -> same day fingerprint (restart-stable)")
    }

    /// A3-25: a LAST session's undated records have no NEXT session, so their
    /// bound is unknown (open) and fails closed for ANY window — the model can't
    /// be sent an undated record it can't place (D33 unique provenance ID needed
    /// before inclusion).
    func testLastSessionUndatedUnknownBoundIssuesAnyWindow() throws {
        let root = makeTempSessionsRoot()
        defer { AmbientStorage.clearCanonicalIndexForTesting(); try? FileManager.default.removeItem(at: root) }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSession("ctx-2026-06-09T10-00-00Z", [undatedSeg("u")], under: root)  // only session -> no next
        let scan = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-08-09T12:00:00Z")),
            sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        XCTAssertTrue(scan.hasSourceIssue, "a last session's undated (no next => unknown bound) fails closed for any window")
    }

    /// A3-25/D151 (flip side): a backfill that writes an in-day `capturedAt`
    /// (even with an OLD mtime) DOES invalidate that day's fingerprint — coverage
    /// relevance is by capturedAt, so it is not hidden behind the mtime.
    func testBackfillWithInDayCapturedAtInvalidatesDayFingerprint() throws {
        let root = makeTempSessionsRoot()
        defer { AmbientStorage.clearCanonicalIndexForTesting(); try? FileManager.default.removeItem(at: root) }
        AmbientStorage.clearCanonicalIndexForTesting()
        let pastDay = Date(timeIntervalSince1970: iso("2026-06-09T00:00:00Z"))

        try writeSession("ctx-2026-06-09T10-00-00Z", [seg("orig", at: iso("2026-06-09T10:00:00Z"))], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T10:05:00Z"), under: root)
        let fp1 = AmbientStorage.dayFingerprint(forDay: pastDay, timeZone: utc, sessionsRoot: root)

        // Backfill: a different session with a June-9 capturedAt but an OLD mtime.
        try writeSession("ctx-2026-06-09T11-00-00Z", [seg("backfill", at: iso("2026-06-09T11:00:00Z"))], under: root)
        try setRawMtime("ctx-2026-06-09T11-00-00Z", iso("2026-06-09T11:05:00Z"), under: root)
        let fp2 = AmbientStorage.dayFingerprint(forDay: pastDay, timeZone: utc, sessionsRoot: root)

        XCTAssertNotEqual(fp1, fp2, "a backfill with an in-day capturedAt invalidates the day (relevance by capturedAt, not mtime)")
    }

    /// A3-25: an undated file whose raw mtime is AFTER its next session's start is
    /// a consistency failure — the bound is non-deterministic (unknown/open) and
    /// fails closed, rather than trusting a possibly-wrong provenance range.
    func testUndatedMtimeAfterNextSessionIsUnknownBoundAndIssues() throws {
        let root = makeTempSessionsRoot()
        defer { AmbientStorage.clearCanonicalIndexForTesting(); try? FileManager.default.removeItem(at: root) }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSession("ctx-2026-06-09T10-00-00Z", [undatedSeg("u")], under: root)
        try writeSession("ctx-2026-06-09T12-00-00Z", [seg("dated", at: iso("2026-06-09T12:05:00Z"))], under: root)
        // S1's mtime is AFTER S2's start (June 13:00 > June 12:00) — inconsistent.
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T13:00:00Z"), under: root)
        try setRawMtime("ctx-2026-06-09T12-00-00Z", iso("2026-06-09T12:10:00Z"), under: root)

        let augScan = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-08-09T12:00:00Z")),
            sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        XCTAssertTrue(augScan.hasSourceIssue,
                      "mtime after the next session start => non-deterministic bound => fails closed for any window")
    }

    /// A3-25/D153 (Cdx point 2): an undated file whose provenance bound lies
    /// ENTIRELY older than the cap is retained data OLDER than coverage — it must
    /// set `truncatedBeforeCoverage`, contribute 0 window segments, and NOT be a
    /// source issue. `upper == cap` is still "entirely older" (half-open bound).
    func testUndatedBoundEntirelyOlderThanCapMarksTruncatedNotIssue() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        // S1 (June 9 10:00) undated-only; S2 (June 9 12:00) gives S1 a next-SID
        // upper of June-12. Make S1 genuinely consistent (mtime + injected ctime
        // both <= June-12).
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z")) }
        try writeSession("ctx-2026-06-09T10-00-00Z", [undatedSeg("u")], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T10:30:00Z"), under: root)
        // S2's dated segment sits well AFTER the anchors below, so it never itself
        // triggers truncation (dated `at < cap`) — the flag can only come from S1's
        // undated older-than-cap bound.
        try writeSession("ctx-2026-06-09T12-00-00Z", [seg("s2", at: iso("2026-06-09T18:00:00Z"))], under: root)
        try setRawMtime("ctx-2026-06-09T12-00-00Z", iso("2026-06-09T12:10:00Z"), under: root)

        // Strictly older: cap (June-16) is after upper (June-12).
        let strict = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-06-09T20:00:00Z")),
            sanityCapHours: 4, timeZone: utc, sessionsRoot: root)  // cap = June-16
        XCTAssertTrue(strict.truncatedBeforeCoverage,
                      "an undated bound entirely older than cap sets truncatedBeforeCoverage")
        XCTAssertEqual(strict.issues.missingTimestampCount, 0,
                       "an older-than-cap undated bound is NOT a source issue (it can't touch the window)")
        XCTAssertFalse(strict.window.contains { $0.text == "u" },
                       "undated records are never included in the window")

        // Exact boundary: cap == upper (June-12). Half-open bound => still older.
        let boundary = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-06-09T16:00:00Z")),
            sanityCapHours: 4, timeZone: utc, sessionsRoot: root)  // cap = June-12 == upper
        XCTAssertTrue(boundary.truncatedBeforeCoverage,
                      "upper == cap is still entirely older (upper <= cap), so truncatedBeforeCoverage holds")
        XCTAssertEqual(boundary.issues.missingTimestampCount, 0, "boundary bound is not a source issue")
    }

    /// A3-25/D153 (Cdx point 2, exclusivity): for the SAME window, a file whose
    /// undated bound is older-than-cap contributes ONLY truncation, while a file
    /// whose undated bound intersects the window contributes ONLY a source issue —
    /// never both, never neither.
    func testUndatedTruncationAndIntersectAreMutuallyExclusive() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        // Consistent ctime per file: OLD (June) <= its June-12 next; IN (Aug) <= its
        // Aug-15 next.
        AmbientStorage.ctimeProviderForTesting = { path in
            path.contains("T10-00-00Z") ? Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z"))
                                        : Date(timeIntervalSince1970: self.iso("2026-08-09T09:30:00Z"))
        }
        // OLD: undated June-9 10:00, next SID June-9 12:00 (upper June-12).
        try writeSession("ctx-2026-06-09T10-00-00Z", [undatedSeg("old")], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T10:30:00Z"), under: root)
        try writeSession("ctx-2026-06-09T12-00-00Z", [seg("june", at: iso("2026-06-09T12:05:00Z"))], under: root)
        try setRawMtime("ctx-2026-06-09T12-00-00Z", iso("2026-06-09T12:10:00Z"), under: root)
        // IN: undated Aug-9 09:00, next SID Aug-9 15:00 (upper Aug-15) — intersects
        // the Aug window below.
        try writeSession("ctx-2026-08-09T09-00-00Z", [undatedSeg("in")], under: root)
        try setRawMtime("ctx-2026-08-09T09-00-00Z", iso("2026-08-09T09:30:00Z"), under: root)
        try writeSession("ctx-2026-08-09T15-00-00Z", [seg("aug", at: iso("2026-08-09T15:05:00Z"))], under: root)
        try setRawMtime("ctx-2026-08-09T15-00-00Z", iso("2026-08-09T15:10:00Z"), under: root)

        let scan = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-08-09T14:00:00Z")),
            sanityCapHours: 48, timeZone: utc, sessionsRoot: root)  // cap = Aug-7 14:00
        XCTAssertTrue(scan.truncatedBeforeCoverage,
                      "the OLD (June) undated bound is entirely older than cap => truncation")
        XCTAssertEqual(scan.issues.missingTimestampCount, 1,
                       "only the IN (Aug) undated bound intersects => exactly one source issue, not double-counted")
    }

    /// A3-25/D153 (Cdx point 2, check b): an unknown/open undated bound (a last
    /// session with no next SID) fails closed as a SOURCE ISSUE but must NOT set
    /// `truncatedBeforeCoverage` — an open bound is not evidence of older-than-cap
    /// data, and asserting truncation would claim evidence that does not exist.
    func testUnknownUndatedBoundIsIssueButNotTruncated() throws {
        let root = makeTempSessionsRoot()
        defer { AmbientStorage.clearCanonicalIndexForTesting(); try? FileManager.default.removeItem(at: root) }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSession("ctx-2026-06-09T10-00-00Z", [undatedSeg("u")], under: root)  // only session -> no next
        let scan = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-08-09T12:00:00Z")),
            sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        XCTAssertTrue(scan.hasSourceIssue, "an unknown/open bound fails closed as a source issue")
        XCTAssertFalse(scan.truncatedBeforeCoverage,
                       "an unknown/open bound must NOT assert older-than-cap truncation evidence")
    }

    /// A3-25 (Cdx supplement): a file whose mtime is <= next SID (looks fine) but
    /// whose st_ctime is AFTER the next SID — a backdated mtime on a
    /// recently-touched file — is a consistency failure: the bound is
    /// non-deterministic (unknown/open) and fails closed for any window. ctime,
    /// unlike mtime, cannot be forged by setAttributes.
    func testUndatedCtimeAfterNextSessionIsUnknownBound() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSession("ctx-2026-06-09T10-00-00Z", [undatedSeg("u")], under: root)
        try writeSession("ctx-2026-06-09T12-00-00Z", [seg("dated", at: iso("2026-06-09T12:05:00Z"))], under: root)
        // mtime looks consistent (June-10 30 <= next SID June-12)...
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T10:30:00Z"), under: root)
        try setRawMtime("ctx-2026-06-09T12-00-00Z", iso("2026-06-09T12:10:00Z"), under: root)
        // ...but the injected ctime is AFTER the next SID (the file was really
        // touched in August) => the backdated mtime is caught, bound is unknown.
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-08-01T00:00:00Z")) }
        let augScan = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-08-09T12:00:00Z")),
            sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        XCTAssertTrue(augScan.hasSourceIssue,
                      "ctime after the next SID => non-deterministic bound => fails closed for any window")
    }

    func testUndatedCtimeUnavailableIsUnknownBound() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSession("ctx-2026-06-09T10-00-00Z", [undatedSeg("u")], under: root)
        try writeSession("ctx-2026-06-09T12-00-00Z", [seg("dated", at: iso("2026-06-09T12:05:00Z"))], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T10:30:00Z"), under: root)
        try setRawMtime("ctx-2026-06-09T12-00-00Z", iso("2026-06-09T12:10:00Z"), under: root)
        AmbientStorage.ctimeProviderForTesting = { _ in nil }
        let scan = AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-08-09T12:00:00Z")),
            sanityCapHours: 48, timeZone: utc, sessionsRoot: root)
        XCTAssertTrue(scan.hasSourceIssue,
                      "unavailable ctime makes the provenance bound non-deterministic")
    }

    // MARK: - Provenance-bound sidecar (ctime hygiene)

    /// Shared setup for the sidecar fixtures: an undated session A whose next
    /// session B fixes its upper bound, with A's mtime consistent (<= B's SID). The
    /// query window is chosen so A's DETERMINISTIC bound [start-63, B) does NOT
    /// intersect it (no issue), while a NON-deterministic bound (open both sides)
    /// intersects ANY window (issue) — so `hasSourceIssue` is the discriminator
    /// between "bound trusted deterministic" and "refuses".
    private func writeSidecarFixtureSessions(under root: URL) throws {
        try writeSession("ctx-2026-06-09T10-00-00Z", [undatedSeg("u")], under: root)
        try writeSession("ctx-2026-06-09T12-00-00Z", [seg("dated", at: iso("2026-06-09T12:05:00Z"))], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T10:30:00Z"), under: root)
        try setRawMtime("ctx-2026-06-09T12-00-00Z", iso("2026-06-09T12:10:00Z"), under: root)
    }
    /// anchor 20:00 with a 4h cap => window [16:00, 20:00); A's deterministic bound
    /// [09:58:57, 12:00) lies entirely below it.
    private func sidecarFixtureScan(under root: URL) -> AmbientStorage.BackwardScan {
        AmbientStorage.scanBackward(
            anchor: Date(timeIntervalSince1970: iso("2026-06-09T20:00:00Z")),
            sanityCapHours: 4, timeZone: utc, sessionsRoot: root)
    }
    private func sidecarPath(under root: URL) -> URL {
        root.appendingPathComponent("ctx-2026-06-09T10-00-00Z/provenance-bound-v1.json")
    }

    /// Sidecar #1: the FIRST deterministic validation persists a trust record.
    /// Before the first scan there is none; a consistent (mtime AND ctime <= next
    /// SID) undated bound writes it. No record => nothing to trust on the next
    /// launch, so this is the precondition for every other sidecar behavior.
    func testSidecarFirstDeterministicValidationWritesTrustRecord() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSidecarFixtureSessions(under: root)
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z")) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath(under: root).path),
                       "no trust record exists before the first scan")
        let scan = sidecarFixtureScan(under: root)
        XCTAssertFalse(scan.hasSourceIssue, "consistent mtime+ctime => deterministic bound, no source issue")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath(under: root).path),
                      "the first deterministic validation writes the provenance trust record")
        let sidecarMode = (try FileManager.default.attributesOfItem(atPath: sidecarPath(under: root).path)[.posixPermissions] as? NSNumber)?.intValue
        let sessionDir = root.appendingPathComponent("ctx-2026-06-09T10-00-00Z")
        let sessionMode = (try FileManager.default.attributesOfItem(atPath: sessionDir.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(sidecarMode, 0o600, "the trust record is private from creation through publish")
        XCTAssertEqual(sessionMode, 0o700, "the existing session directory converges to private permissions")
    }

    /// Sidecar #2 (THE ctime-fragility fix): once validated, a benign ctime flip
    /// (chmod/rsync/backup restore, even while the app is off) across a restart must
    /// NOT revoke the bound. Scan 1 validates + writes the record. Then ctime jumps
    /// to AFTER the next SID (the benign flip) and the index is cleared (restart):
    /// the record still matches (same sessionId/SHA/byteCount/nextSessionId/policy),
    /// so the bound stays deterministic and the query still resolves.
    /// OLD-FAIL (P0-848 re-materialized): DELETE the record and repeat the same
    /// flip — with no trust record the live ctime>next check fails closed and EVERY
    /// window refuses. The two halves share one flip; only the record differs.
    func testSidecarSurvivesBenignCtimeFlipAcrossRestart() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSidecarFixtureSessions(under: root)

        // Scan 1: consistent ctime => deterministic => record written.
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z")) }
        XCTAssertFalse(sidecarFixtureScan(under: root).hasSourceIssue, "first validation is deterministic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath(under: root).path), "record written")

        // Benign ctime flip to AFTER the next SID + restart (index cleared).
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-08-01T00:00:00Z")) }
        AmbientStorage.clearCanonicalIndexForTesting()
        XCTAssertFalse(sidecarFixtureScan(under: root).hasSourceIssue,
                       "a benign ctime flip after restart does NOT revoke the trusted deterministic bound")

        // OLD-FAIL: remove the trust record, same flip => refuses for any window.
        try FileManager.default.removeItem(at: sidecarPath(under: root))
        AmbientStorage.clearCanonicalIndexForTesting()
        XCTAssertTrue(sidecarFixtureScan(under: root).hasSourceIssue,
                      "without the record the ctime>next flip fails closed (P0-848) — the record is load-bearing")
    }

    /// Sidecar #3 (content-addressed): a stale record must NOT trust a file whose
    /// BYTES changed, even at identical size+mtime. Rewriting the undated content
    /// (same size, same mtime) advances the SHA; the record's rawSHA256 no longer
    /// matches, so trust falls back to the live ctime check — which (flipped past
    /// next) now refuses. Proves the bound is bound to the content, not just identity.
    func testSidecarDoesNotTrustChangedBytesAtSameSizeAndMtime() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSidecarFixtureSessions(under: root)
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z")) }
        XCTAssertFalse(sidecarFixtureScan(under: root).hasSourceIssue, "first validation is deterministic")

        // Same-size ("u"->"x", both 1 ASCII char) same-mtime rewrite => new SHA.
        try writeSession("ctx-2026-06-09T10-00-00Z", [undatedSeg("x")], under: root)
        try setRawMtime("ctx-2026-06-09T10-00-00Z", iso("2026-06-09T10:30:00Z"), under: root)
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-08-01T00:00:00Z")) }
        AmbientStorage.clearCanonicalIndexForTesting()
        XCTAssertTrue(sidecarFixtureScan(under: root).hasSourceIssue,
                      "a stale record never trusts changed bytes (SHA mismatch) => live ctime>next refuses")
    }

    /// Sidecar #4 (identity): the record binds the NEXT session's identity. Inserting
    /// a new session between A and B changes A's `nextSessionId`, so the record no
    /// longer matches and trust falls back to the live ctime check (flipped => refuses).
    /// Guards against trusting a bound whose upper endpoint silently moved.
    func testSidecarInvalidatedWhenNextSessionIdentityChanges() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSidecarFixtureSessions(under: root)
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z")) }
        XCTAssertFalse(sidecarFixtureScan(under: root).hasSourceIssue, "first validation is deterministic")

        // A new session between A(10:00) and B(12:00): A's next is now 11:00, not B.
        try writeSession("ctx-2026-06-09T11-00-00Z", [seg("mid", at: iso("2026-06-09T11:05:00Z"))], under: root)
        try setRawMtime("ctx-2026-06-09T11-00-00Z", iso("2026-06-09T11:10:00Z"), under: root)
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-08-01T00:00:00Z")) }
        XCTAssertTrue(sidecarFixtureScan(under: root).hasSourceIssue,
                      "a changed next-session identity invalidates a live cache hit => live ctime>next refuses")
    }

    func testSidecarPolicyChangeInvalidatesLiveCanonicalSnapshot() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSidecarFixtureSessions(under: root)
        try writePreset("ctx-2026-06-09T10-00-00Z", chunkSeconds: 30, under: root)
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z")) }
        XCTAssertFalse(sidecarFixtureScan(under: root).hasSourceIssue)

        try writePreset("ctx-2026-06-09T10-00-00Z", chunkSeconds: 20, under: root)
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-08-01T00:00:00Z")) }
        XCTAssertTrue(sidecarFixtureScan(under: root).hasSourceIssue,
                      "a preset policy change invalidates the live canonical snapshot even when raw bytes are unchanged")
    }

    /// Sidecar #5 (derived, re-generatable): a CORRUPT record is silently ignored
    /// (never quarantined) and rebuilt. With a consistent live ctime the bound is
    /// re-validated deterministic and a fresh, valid record replaces the garbage.
    func testSidecarCorruptRecordIsIgnoredAndRebuilt() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSidecarFixtureSessions(under: root)
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z")) }
        XCTAssertFalse(sidecarFixtureScan(under: root).hasSourceIssue, "first validation is deterministic")

        // Corrupt the record; ctime stays consistent so the live check still passes.
        try Data("not-json{".utf8).write(to: sidecarPath(under: root))
        AmbientStorage.clearCanonicalIndexForTesting()
        XCTAssertFalse(sidecarFixtureScan(under: root).hasSourceIssue,
                       "a corrupt record is ignored, the bound re-validated deterministic")
        let rebuilt = try Data(contentsOf: sidecarPath(under: root))
        let obj = try JSONSerialization.jsonObject(with: rebuilt) as? [String: Any]
        XCTAssertNotNil(obj?["rawSHA256"], "the garbage was replaced by a fresh valid trust record")
    }

    /// Sidecar #6 (non-sticky write failure): if the record cannot be written, the
    /// determinism of THIS launch still holds (via the live ctime check — the
    /// pre-sidecar baseline) and the raw file is untouched. The failure is diagnosed
    /// (os.Logger) but leaves no record on disk, so it is not sticky.
    func testSidecarUnwritableLeavesRawUntouchedAndStillDeterministicThisLaunch() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.sidecarWriteShouldFailForTesting = false
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSidecarFixtureSessions(under: root)
        let raw = root.appendingPathComponent("ctx-2026-06-09T10-00-00Z/transcripts/raw.jsonl")
        let bytesBefore = try Data(contentsOf: raw)
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: raw.path)[.modificationDate] as? Date

        AmbientStorage.sidecarWriteShouldFailForTesting = true
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z")) }
        XCTAssertFalse(sidecarFixtureScan(under: root).hasSourceIssue,
                       "determinism this launch holds via the live ctime check even when the record cannot be written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath(under: root).path),
                       "a failed write leaves no record (non-sticky next launch)")
        XCTAssertEqual(try Data(contentsOf: raw), bytesBefore, "the raw file bytes are untouched by a sidecar write failure")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: raw.path)[.modificationDate] as? Date,
                       mtimeBefore, "the raw file mtime is untouched by a sidecar write failure")
    }

    /// Sidecar #7 (atomic last-writer-wins): concurrent scans of the same session
    /// each try to write the record; the UUID-temp + rename(2) publish means the
    /// on-disk file is ALWAYS one complete valid record, never a torn/partial write.
    func testSidecarConcurrentScansPublishOneValidAtomicRecord() throws {
        let root = makeTempSessionsRoot()
        defer {
            AmbientStorage.ctimeProviderForTesting = nil
            AmbientStorage.clearCanonicalIndexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        AmbientStorage.clearCanonicalIndexForTesting()
        try writeSidecarFixtureSessions(under: root)
        AmbientStorage.ctimeProviderForTesting = { _ in Date(timeIntervalSince1970: self.iso("2026-06-09T10:30:00Z")) }

        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            _ = sidecarFixtureScan(under: root)
        }
        let data = try Data(contentsOf: sidecarPath(under: root))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["rawSHA256"], "concurrent writers leave exactly one complete, valid record (atomic rename)")
        XCTAssertFalse(sidecarFixtureScan(under: root).hasSourceIssue, "the published record trusts the deterministic bound")
    }


    /// A3-01: an EXPLICIT selection with a broken day source flags
    /// sourceReadIncomplete and KEEPS the selection — a source failure must not
    /// masquerade as scene loss (old impl reconciled to empty and cleared it).
    func testExplicitSourceIssueKeepsSelectionAndFlagsSourceReadIncomplete() throws {
        let root = makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 20; c.hour = 12; c.timeZone = jst
        let pastDay = Calendar(identifier: .gregorian).date(from: c)!
        let dayStart = startOfDayJST(pastDay).timeIntervalSince1970
        let segs = [seg("A", at: dayStart + 100), seg("B", at: dayStart + 200)]
        let sceneID = AmbientLogGrouping.scenes(from: segs, timeZone: jst)[0].id
        try writeSession("ctx-day", segs, under: root)

        // Make the day's source unreadable AFTER computing the scene id.
        let raw = root.appendingPathComponent("ctx-day/transcripts/raw.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: raw.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: raw.path) }

        let model = AmbientLogModel()
        model.selectedDay = startOfDayJST(pastDay)
        model.selectedSceneIDs = [sceneID]
        let prepared = model.prepareLogQuery(actionId: "slot-0", instruction: "x", sessionsRoot: root)

        XCTAssertTrue(prepared.envelope.sourceReadIncomplete, "a broken day source flags sourceReadIncomplete")
        XCTAssertFalse(prepared.envelope.staleScopeCleared, "a source failure is NOT treated as scene loss")
        XCTAssertEqual(prepared.envelope.scopeOverride, [sceneID], "the user's selection is preserved, not cleared")

        var dispatched = 0
        model.commitPreparedLogQuery(prepared) { _, _ in dispatched += 1 }
        XCTAssertEqual(model.selectedSceneIDs, [sceneID], "commit keeps the user's selection")
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
