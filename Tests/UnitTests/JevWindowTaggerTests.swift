import XCTest
@testable import ClawGate

/// `JevWindowTagger` gates whether a 60s ambient window gets asked about
/// (`decision`), and on a go, asks and records the answer next to the rule
/// extractor's events (`tag`). No network: `ask` is always stubbed.
final class JevWindowTaggerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func tempLedger() -> (JevLedger, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-tagger-tests-\(UUID().uuidString)", isDirectory: true)
        return (JevLedger(root: root), root)
    }

    private func makeBreaker(suite: String) -> (JevBreaker, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        return (JevBreaker(defaults: defaults), defaults)
    }

    private func sampleResult() -> JevResult {
        JevResult(answers: ["decision": 0.9], invalid: [],
                  usage: JevUsage(inputTokens: 10, outputTokens: 2),
                  model: JevClient.model, latencyMs: 42)
    }

    // MARK: - windowKey

    func testWindowKeyIsStableForTheSameIds() {
        let a = JevWindowTagger.windowKey(segmentIds: ["seg-1", "seg-2"])
        let b = JevWindowTagger.windowKey(segmentIds: ["seg-1", "seg-2"])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 16)
    }

    func testWindowKeyDiffersForDifferentOrderOrSet() {
        let ordered = JevWindowTagger.windowKey(segmentIds: ["seg-1", "seg-2"])
        let reordered = JevWindowTagger.windowKey(segmentIds: ["seg-2", "seg-1"])
        let differentSet = JevWindowTagger.windowKey(segmentIds: ["seg-1", "seg-3"])
        XCTAssertNotEqual(ordered, reordered)
        XCTAssertNotEqual(ordered, differentSet)
    }

    // MARK: - state(from:)

    func testStateRendersSpeakerLabelsInUTC() {
        let utc = TimeZone(identifier: "UTC")!
        let lines: [AmbientIngestProducer.Line] = [
            AmbientIngestProducer.Line(text: "明日行くね", speaker: "self",
                                       capturedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            AmbientIngestProducer.Line(text: "了解です", speaker: "other",
                                       capturedAt: Date(timeIntervalSince1970: 1_790_000_060)),
        ]
        let state = JevWindowTagger.state(from: lines, timeZone: utc)
        XCTAssertTrue(state.contains("ご主人様: 明日行くね"))
        XCTAssertTrue(state.contains("相手: 了解です"))
    }

    // MARK: - decision

    func testEmptySegmentIdsSkipsAsEmpty() {
        let tagger = JevWindowTagger(ledger: tempLedger().0, breaker: JevBreaker(),
                                     isEnabled: { true }, isConfigured: { true },
                                     ask: { _, _ in self.sampleResult() })
        XCTAssertEqual(tagger.decision(segmentIds: [], now: now), .failure(.empty))
    }

    func testDisabledSkips() {
        let tagger = JevWindowTagger(ledger: tempLedger().0, breaker: JevBreaker(),
                                     isEnabled: { false }, isConfigured: { true },
                                     ask: { _, _ in self.sampleResult() })
        XCTAssertEqual(tagger.decision(segmentIds: ["seg-1"], now: now), .failure(.disabled))
    }

    func testUnconfiguredSkips() {
        let tagger = JevWindowTagger(ledger: tempLedger().0, breaker: JevBreaker(),
                                     isEnabled: { true }, isConfigured: { false },
                                     ask: { _, _ in self.sampleResult() })
        XCTAssertEqual(tagger.decision(segmentIds: ["seg-1"], now: now), .failure(.unconfigured))
    }

    func testOpenBreakerSkips() {
        let suite = "clawgate.tests.jev.tagger.breaker.\(UUID().uuidString)"
        var (breaker, defaults) = makeBreaker(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        breaker.record(ok: false, at: now.addingTimeInterval(-120))
        breaker.record(ok: false, at: now.addingTimeInterval(-60))
        breaker.record(ok: false, at: now.addingTimeInterval(-1))

        let tagger = JevWindowTagger(ledger: tempLedger().0, breaker: breaker,
                                     isEnabled: { true }, isConfigured: { true },
                                     ask: { _, _ in self.sampleResult() })
        XCTAssertEqual(tagger.decision(segmentIds: ["seg-1"], now: now), .failure(.breakerOpen))
    }

    func testAlreadyAskedSkips() {
        let (ledger, root) = tempLedger()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = JevWindowTagger.windowKey(segmentIds: ["seg-1"])
        ledger.record(JevTagEntry(key: key, segmentIds: ["seg-1"], questionVersion: JevQuestions.version,
                                  answers: [:], invalid: [], usage: JevTagEntry.Usage(inputTokens: 0, outputTokens: 0),
                                  latencyMs: 1, at: now))

        let tagger = JevWindowTagger(ledger: ledger, breaker: JevBreaker(),
                                     isEnabled: { true }, isConfigured: { true },
                                     ask: { _, _ in self.sampleResult() })
        XCTAssertEqual(tagger.decision(segmentIds: ["seg-1"], now: now), .failure(.alreadyAsked))
    }

    func testAllChecksPassingReturnsTheWindowKey() {
        let tagger = JevWindowTagger(ledger: tempLedger().0, breaker: JevBreaker(),
                                     isEnabled: { true }, isConfigured: { true },
                                     ask: { _, _ in self.sampleResult() })
        let expected = JevWindowTagger.windowKey(segmentIds: ["seg-1"])
        XCTAssertEqual(tagger.decision(segmentIds: ["seg-1"], now: now), .success(expected))
    }

    // MARK: - tag

    func testTagOnSuccessWritesALedgerLineAndRecordsABreakerSuccess() {
        let (ledger, root) = tempLedger()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "clawgate.tests.jev.tagger.tag.ok.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var tagger = JevWindowTagger(ledger: ledger, breaker: JevBreaker(defaults: defaults),
                                     isEnabled: { true }, isConfigured: { true },
                                     ask: { _, _ in self.sampleResult() })
        let lines = [AmbientIngestProducer.Line(text: "明日やります", speaker: "self", capturedAt: now)]
        let outcome = tagger.tag(lines: lines, segmentIds: ["seg-1"],
                                 ruleEventTypes: ["todo"], now: now)

        guard case .asked = outcome else { return XCTFail("expected .asked, got \(outcome)") }
        XCTAssertTrue(ledger.hasAsked(key: JevWindowTagger.windowKey(segmentIds: ["seg-1"]), on: now))

        let raw = defaults.array(forKey: "clawgate.jev.breaker") as? [[String: Any]]
        XCTAssertEqual(raw?.count, 1)
        XCTAssertEqual(raw?.first?["ok"] as? Bool, true)
    }

    func testTagOnFailureRecordsABreakerFailureAndWritesNoLine() {
        let (ledger, root) = tempLedger()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "clawgate.tests.jev.tagger.tag.fail.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var tagger = JevWindowTagger(ledger: ledger, breaker: JevBreaker(defaults: defaults),
                                     isEnabled: { true }, isConfigured: { true },
                                     ask: { _, _ in throw JevError.http(500) })
        let lines = [AmbientIngestProducer.Line(text: "明日やります", speaker: "self", capturedAt: now)]
        let outcome = tagger.tag(lines: lines, segmentIds: ["seg-1"],
                                 ruleEventTypes: ["todo"], now: now)

        guard case .failed(let error) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertEqual(error, .http(500))
        XCTAssertFalse(ledger.hasAsked(key: JevWindowTagger.windowKey(segmentIds: ["seg-1"]), on: now))

        let raw = defaults.array(forKey: "clawgate.jev.breaker") as? [[String: Any]]
        XCTAssertEqual(raw?.count, 1)
        XCTAssertEqual(raw?.first?["ok"] as? Bool, false)
    }
}
