import XCTest
@testable import ClawGate

/// `JevLogRelevance` shadow-scores a Log question's relevance against that
/// day's transcript, 90-second block by block, in a single Jev call — this
/// measures agreement with the model's own segment choice
/// (`PetLogContextDecision.includedSegmentIds`) and changes nothing about
/// the Log request itself. No network: `ask` is always stubbed.
final class JevLogRelevanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func seg(_ id: String, at: Double, text: String = "hello", speaker: String? = "self") -> PetLogRawSegment {
        PetLogRawSegment(id: id, capturedAt: at, startSeconds: 0, endSeconds: 1, speaker: speaker, text: text)
    }

    private func envelope(segments: [PetLogRawSegment], instruction: String = "今日は何をした？",
                          requestId: String = "req-1") -> PetLogQueryEnvelope {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        return PetLogQueryEnvelope(
            requestId: requestId, actionId: "free", instruction: instruction,
            queryTimestamp: ts, anchorTimestamp: ts, scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true,
            segments: segments
        )
    }

    private func tempLedger() -> (JevLedger, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-log-relevance-tests-\(UUID().uuidString)", isDirectory: true)
        return (JevLedger(root: root), root)
    }

    private func tempStorageRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-log-relevance-store-\(UUID().uuidString)", isDirectory: true)
    }

    /// An isolated `UserDefaults` suite so the breaker never touches
    /// `.standard` (and the real app's breaker state) during tests. The
    /// caller is responsible for removing the suite when done.
    private func makeBreaker() -> (JevBreaker, UserDefaults, String) {
        let suite = "clawgate.tests.jev.log-relevance.breaker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (JevBreaker(defaults: defaults), defaults, suite)
    }

    private func sampleResult(answers: [String: Double]) -> JevResult {
        JevResult(answers: answers, invalid: [],
                  usage: JevUsage(inputTokens: 10, outputTokens: 2),
                  model: JevClient.model, latencyMs: 42)
    }

    // MARK: - groupBlocks

    func testGroupBlocksMergesSegmentsWithinTheGap() {
        let segments = [
            seg("s1", at: 1000, text: "a"),
            seg("s2", at: 1010, text: "b"),
            seg("s3", at: 1020, text: "c"),
        ]
        let blocks = JevLogRelevanceLayout.groupBlocks(segments: segments)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].map(\.id), ["s1", "s2", "s3"])
    }

    func testGroupBlocksSplitsOnALargeGap() {
        let segments = [
            seg("s1", at: 1000, text: "a"),
            seg("s2", at: 1010, text: "b"),
            seg("s3", at: 1010 + 120, text: "c"),
        ]
        let blocks = JevLogRelevanceLayout.groupBlocks(segments: segments)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].map(\.id), ["s1", "s2"])
        XCTAssertEqual(blocks[1].map(\.id), ["s3"])
    }

    // MARK: - questions

    func testQuestionsProduceOneIdPerBlockNamingItsOwnMarkerAndInstruction() {
        let questions = JevLogRelevanceLayout.questions(blockCount: 3, instruction: "傘の話は出た？")
        XCTAssertEqual(Set(questions.keys), ["b0", "b1", "b2"])
        for (index, id) in ["b0", "b1", "b2"].enumerated() {
            let question = questions[id]!
            XCTAssertTrue(question.instructions.contains("[B\(index)]"))
            XCTAssertTrue(question.instructions.contains("傘の話は出た？"))
        }
    }

    // MARK: - state

    func testStatePutsMarkersInOrder() {
        let blocks = [
            [seg("s1", at: 1000, text: "a")],
            [seg("s2", at: 1200, text: "b")],
        ]
        let state = JevLogRelevanceLayout.state(blocks: blocks, timeZone: TimeZone(identifier: "UTC")!)
        let b0Range = state.range(of: "[B0]")!
        let b1Range = state.range(of: "[B1]")!
        XCTAssertTrue(b0Range.lowerBound < b1Range.lowerBound)
        XCTAssertTrue(state.contains("a"))
        XCTAssertTrue(state.contains("b"))
    }

    func testStateDropsWholeOldestBlocksWhenOverBudget() {
        let blocks = [
            [seg("old", at: 1000, text: String(repeating: "古", count: 50))],
            [seg("new", at: 2000, text: String(repeating: "新", count: 50))],
        ]
        let state = JevLogRelevanceLayout.state(blocks: blocks, maxChars: 60, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertFalse(state.contains("[B0]"))
        XCTAssertTrue(state.contains("[B1]"))
        XCTAssertFalse(state.contains("古"))
        XCTAssertTrue(state.contains("新"))
    }

    // MARK: - shadow

    func testShadowWithStubbedAskReturnsPerBlockScoresAndWritesALedgerLine() {
        let (ledger, root) = tempLedger()
        defer { try? FileManager.default.removeItem(at: root) }
        let (breaker, defaults, suite) = makeBreaker()
        defer { defaults.removePersistentDomain(forName: suite) }
        let segments = [seg("s1", at: 1000), seg("s2", at: 1010 + 120)]
        let env = envelope(segments: segments)

        let relevance = JevLogRelevance(ledger: ledger, breaker: breaker,
                                        isEnabled: { true }, isConfigured: { true },
                                        ask: { _, _ in self.sampleResult(answers: ["b0": 0.9, "b1": 0.1]) })
        let blocks = JevLogRelevanceLayout.groupBlocks(segments: segments)
        let result = relevance.shadow(envelope: env, blocks: blocks, now: now)

        XCTAssertNil(result.skipped)
        XCTAssertEqual(result.scores, ["b0": 0.9, "b1": 0.1])
        XCTAssertEqual(result.blockSegmentIds, [["s1"], ["s2"]])
        XCTAssertEqual(result.requestId, "req-1")
        let key = JevLogRelevance.requestKey(segmentIds: env.segments.map(\.id), instruction: env.instruction)
        XCTAssertTrue(ledger.hasAsked(key: key, on: now))
    }

    func testShadowOnAskFailureSetsSkippedAndWritesNoLedgerLine() {
        let (ledger, root) = tempLedger()
        defer { try? FileManager.default.removeItem(at: root) }
        let (breaker, defaults, suite) = makeBreaker()
        defer { defaults.removePersistentDomain(forName: suite) }
        let segments = [seg("s1", at: 1000)]
        let env = envelope(segments: segments)

        let relevance = JevLogRelevance(ledger: ledger, breaker: breaker,
                                        isEnabled: { true }, isConfigured: { true },
                                        ask: { _, _ in throw JevError.http(500) })
        let blocks = JevLogRelevanceLayout.groupBlocks(segments: segments)
        let result = relevance.shadow(envelope: env, blocks: blocks, now: now)

        XCTAssertEqual(result.skipped, "failed")
        XCTAssertTrue(result.scores.isEmpty)
        let key = JevLogRelevance.requestKey(segmentIds: env.segments.map(\.id), instruction: env.instruction)
        XCTAssertFalse(ledger.hasAsked(key: key, on: now))
    }

    func testShadowSkipsWhenDisabledWithoutCallingAsk() {
        let (ledger, root) = tempLedger()
        defer { try? FileManager.default.removeItem(at: root) }
        let (breaker, defaults, suite) = makeBreaker()
        defer { defaults.removePersistentDomain(forName: suite) }
        let segments = [seg("s1", at: 1000)]
        let env = envelope(segments: segments)
        var called = false

        let relevance = JevLogRelevance(ledger: ledger, breaker: breaker,
                                        isEnabled: { false }, isConfigured: { true },
                                        ask: { _, _ in called = true; return self.sampleResult(answers: [:]) })
        let blocks = JevLogRelevanceLayout.groupBlocks(segments: segments)
        let result = relevance.shadow(envelope: env, blocks: blocks, now: now)

        XCTAssertEqual(result.skipped, "disabled")
        XCTAssertFalse(called)
    }

    func testShadowKeyDiffersForTheSameSegmentsUnderADifferentInstruction() {
        let (ledger, root) = tempLedger()
        defer { try? FileManager.default.removeItem(at: root) }
        let (breaker, defaults, suite) = makeBreaker()
        defer { defaults.removePersistentDomain(forName: suite) }
        let segments = [seg("s1", at: 1000)]
        let firstEnv = envelope(segments: segments, instruction: "傘の話は出た？", requestId: "req-a")
        let secondEnv = envelope(segments: segments, instruction: "予定は決まった？", requestId: "req-b")

        let relevance = JevLogRelevance(ledger: ledger, breaker: breaker,
                                        isEnabled: { true }, isConfigured: { true },
                                        ask: { _, _ in self.sampleResult(answers: ["b0": 0.5]) })
        let blocks = JevLogRelevanceLayout.groupBlocks(segments: segments)
        let firstResult = relevance.shadow(envelope: firstEnv, blocks: blocks, now: now)
        let secondResult = relevance.shadow(envelope: secondEnv, blocks: blocks, now: now)

        XCTAssertNil(firstResult.skipped)
        XCTAssertNil(secondResult.skipped, "a different instruction over the same segments must still be asked")
    }

    // MARK: - JevLogRelevanceStore

    func testStoreRoundTripsAShadowAndAnAttachedModelDecisionJoinedByRequestId() {
        let root = tempStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let shadow = LogRelevanceShadow(
            requestId: "req-join", at: now, questionVersion: JevQuestions.version,
            instruction: "傘の話は出た？", blockSegmentIds: [["s1"], ["s2"]],
            scores: ["b0": 0.9, "b1": 0.2], invalid: [], skipped: nil, modelIncludedSegmentIds: nil
        )
        JevLogRelevanceStore.append(shadow, root: root)
        JevLogRelevanceStore.attachModelDecision(requestId: "req-join", includedSegmentIds: ["s1"],
                                                 at: now, root: root)

        let joined = JevLogRelevanceStore.readJoined(day: now, root: root)
        let record = joined["req-join"]
        XCTAssertEqual(record?.shadow?.scores, ["b0": 0.9, "b1": 0.2])
        XCTAssertEqual(record?.modelIncludedSegmentIds, ["s1"])
    }
}
