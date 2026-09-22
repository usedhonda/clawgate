import XCTest
@testable import ClawGate

/// `JevLedger` appends one JSONL line per asked window to a temp root and
/// reads it back for dedupe (`hasAsked`) and daily totals.
final class JevLedgerTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeLedger() -> (JevLedger, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-ledger-tests-\(UUID().uuidString)", isDirectory: true)
        return (JevLedger(root: root), root)
    }

    private func entry(key: String, inputTokens: Int, outputTokens: Int, at: Date) -> JevTagEntry {
        JevTagEntry(key: key, segmentIds: ["seg-1"], questionVersion: JevQuestions.version,
                   answers: ["decision": 0.9], invalid: [],
                   usage: JevTagEntry.Usage(inputTokens: inputTokens, outputTokens: outputTokens),
                   latencyMs: 42, at: at)
    }

    func testRecordingTwoEntriesSumsCallsTokensAndCost() throws {
        let (ledger, root) = makeLedger()
        defer { try? FileManager.default.removeItem(at: root) }

        ledger.record(entry(key: "win-1", inputTokens: 100, outputTokens: 10, at: day))
        ledger.record(entry(key: "win-2", inputTokens: 200, outputTokens: 20, at: day.addingTimeInterval(60)))

        let totals = ledger.daily(on: day)
        XCTAssertEqual(totals.calls, 2)
        XCTAssertEqual(totals.inputTokens, 300)
        XCTAssertEqual(totals.outputTokens, 30)
        XCTAssertEqual(totals.costUSD, 300.0 * 0.042 / 1_000_000, accuracy: 1e-12)
    }

    func testHasAskedIsTrueForARecordedKeyAndFalseOtherwise() throws {
        let (ledger, root) = makeLedger()
        defer { try? FileManager.default.removeItem(at: root) }

        ledger.record(entry(key: "win-1", inputTokens: 1, outputTokens: 1, at: day))
        XCTAssertTrue(ledger.hasAsked(key: "win-1", on: day))
        XCTAssertFalse(ledger.hasAsked(key: "win-2", on: day))
    }

    func testEachAppendedLineIsValidJSON() throws {
        let (ledger, root) = makeLedger()
        defer { try? FileManager.default.removeItem(at: root) }

        ledger.record(entry(key: "win-1", inputTokens: 1, outputTokens: 2, at: day))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let tagFile = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("tags-") })
        let text = try XCTUnwrap(String(data: Data(contentsOf: tagFile), encoding: .utf8))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)))
    }

    func testCostUSDMatchesThePricingConstant() {
        XCTAssertEqual(JevLedger.costUSD(inputTokens: 1_000_000), 0.042, accuracy: 1e-12)
        XCTAssertEqual(JevLedger.costUSD(inputTokens: 0), 0)
    }
}
