import XCTest
@testable import ClawGate

/// `JevMeetingTagger` splits a meeting's transcript into batches and shadow-
/// tags each one with Jev through `JevWindowTagger` — nothing here touches
/// the minutes request. No network: `ask` is always stubbed.
final class JevMeetingTaggerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func segment(_ text: String, at: Double, index: Int) -> TranscriptSegment {
        var s = TranscriptSegment(startSeconds: Double(index), endSeconds: Double(index) + 1, text: text)
        s.capturedAt = at
        s.speaker = "self"
        return s
    }

    private func record(id: String = "mtg-test") -> MeetingRecord {
        MeetingRecord(id: id, source: "meet", startedAt: 1_790_000_000, endedAt: 1_790_003_600,
                     timeZone: "Asia/Tokyo", title: "Weekly sync", conferenceCode: "abc-defg-hij",
                     participants: [], minutesState: "none", minutesError: nil)
    }

    private func tempStore() -> (MeetingStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawgate-jev-meeting-tests-\(UUID().uuidString)", isDirectory: true)
        return (MeetingStore(root: root), root)
    }

    private func makeTagger(suite: String, ask: @escaping (String, [String: JevQuestion]) throws -> JevResult) -> JevWindowTagger {
        let ledgerRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jev-meeting-tagger-ledger-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: suite)!
        return JevWindowTagger(ledger: JevLedger(root: ledgerRoot), breaker: JevBreaker(defaults: defaults),
                               isEnabled: { true }, isConfigured: { true }, ask: ask)
    }

    // MARK: - batches

    func testBatchesAreContiguousOrderPreservingAndCappedByChars() {
        let segments = (0..<10).map { segment(String(repeating: "あ", count: 1_000), at: 1_790_000_000 + Double($0), index: $0) }
        let batches = JevMeetingTagger.batches(segments, maxChars: 2_500, maxSegments: 80)
        XCTAssertEqual(batches.count, 5)
        for batch in batches { XCTAssertEqual(batch.count, 2) }
        // Order preserved and every segment present exactly once.
        let flattened = batches.flatMap { $0 }
        XCTAssertEqual(flattened.map(\.startSeconds), segments.map(\.startSeconds))
    }

    func testMaxSegmentsAlsoClosesABatch() {
        let segments = (0..<6).map { segment("short", at: 1_790_000_000 + Double($0), index: $0) }
        let batches = JevMeetingTagger.batches(segments, maxChars: 100_000, maxSegments: 2)
        XCTAssertEqual(batches.count, 3)
        for batch in batches { XCTAssertEqual(batch.count, 2) }
    }

    func testEmptyInputProducesNoBatches() {
        XCTAssertEqual(JevMeetingTagger.batches([], maxChars: 1_000, maxSegments: 10).count, 0)
    }

    // MARK: - shadow

    func testShadowAsksEveryBatchAndRollsUpThePeak() {
        let suite = "clawgate.tests.jev.meeting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Sized so `shadow`'s default `maxChars: 6_000` closes a batch every
        // 2 segments (2 * 3_000 == 6_000, a 3rd would exceed it): 10
        // segments become 5 batches.
        let segments = (0..<10).map { segment(String(repeating: "あ", count: 3_000), at: 1_790_000_000 + Double($0), index: $0) }
        let expectedBatches = JevMeetingTagger.batches(segments).count
        XCTAssertEqual(expectedBatches, 5)
        var callCount = 0
        let tagger = JevMeetingTagger(makeTagger: {
            self.makeTagger(suite: suite) { _, _ in
                callCount += 1
                // Later batches score higher, so `peak` must pick the max.
                return JevResult(answers: ["decision": Double(callCount) * 0.1], invalid: [],
                                 usage: JevUsage(inputTokens: 1, outputTokens: 1), model: JevClient.model, latencyMs: 1)
            }
        })

        // `shadow` calls `makeTagger()` exactly once for the whole meeting,
        // so every batch is asked through the same tagger instance (and its
        // ledger), matching how `JevWindowTagger` is meant to be reused
        // across a run.
        let result = tagger.shadow(record: record(), segments: segments, now: now)

        XCTAssertEqual(result.meetingId, "mtg-test")
        XCTAssertEqual(result.questionVersion, JevQuestions.version)
        XCTAssertEqual(result.batches.count, expectedBatches)
        XCTAssertEqual(callCount, expectedBatches)
        XCTAssertEqual(result.peak["decision"], Double(expectedBatches) * 0.1)
        for batch in result.batches {
            XCTAssertNil(batch.skipped)
            XCTAssertFalse(batch.segmentIds.isEmpty)
        }
    }

    func testShadowMarksAFailedBatchAsSkippedWithTheErrorAndKeepsItsAnswersEmpty() {
        let suite = "clawgate.tests.jev.meeting.fail.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let segments = [segment("短い発言", at: 1_790_000_000, index: 0)]
        let tagger = JevMeetingTagger(makeTagger: {
            self.makeTagger(suite: suite) { _, _ in throw JevError.http(500) }
        })

        let result = tagger.shadow(record: record(), segments: segments, now: now)

        XCTAssertEqual(result.batches.count, 1)
        XCTAssertEqual(result.batches.first?.skipped, "failed:http(500)")
        XCTAssertEqual(result.batches.first?.answers, [:])
        XCTAssertTrue(result.peak.isEmpty)
    }

    // MARK: - saveJevShadow / loadJevShadow

    func testSaveAndLoadRoundTrips() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let shadow = MeetingJevShadow(
            meetingId: "mtg-test", questionVersion: JevQuestions.version, at: now,
            batches: [BatchShadow(key: "k1", segmentIds: ["seg-1"], answers: ["decision": 0.8], invalid: [], skipped: nil)],
            peak: ["decision": 0.8])
        store.saveJevShadow(shadow, for: record())

        let loaded = store.loadJevShadow(id: "mtg-test")
        XCTAssertEqual(loaded, shadow)
    }

    func testLoadJevShadowIsNilWhenNoFileExists() {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(store.loadJevShadow(id: "mtg-missing"))
    }
}
