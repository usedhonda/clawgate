import XCTest
@testable import ClawGate

final class TmuxOutputParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeWatcher() -> TmuxInboundWatcher {
        let defaults = UserDefaults(suiteName: "clawgate.tests.tmux-parser")!
        defaults.removePersistentDomain(forName: "clawgate.tests.tmux-parser")
        let cfg = ConfigStore(defaults: defaults)
        let logger = AppLogger(configStore: cfg)
        let ccClient = CCStatusBarClient(url: "ws://localhost:0/unused", logger: logger)
        return TmuxInboundWatcher(ccClient: ccClient, eventBus: EventBus(), logger: logger, configStore: cfg)
    }

    // MARK: - detectQuestion

    func testDetectQuestionWithSelectorPattern() {
        let watcher = makeWatcher()
        let output = """
        Some previous output here

        ? Which library should we use for date formatting?
          ❯ date-fns (Recommended)
          ○ moment
          ○ dayjs
        """
        let q = watcher.detectQuestion(from: output)
        XCTAssertNotNil(q)
        XCTAssertEqual(q?.questionText, "? Which library should we use for date formatting?")
        XCTAssertEqual(q?.options.count, 3)
        XCTAssertEqual(q?.options[0], "date-fns (Recommended)")
        XCTAssertEqual(q?.selectedIndex, 0)
    }

    func testDetectQuestionWithBulletPattern() {
        let watcher = makeWatcher()
        let output = """
        ? Do you want to continue?
          ● Yes
          ○ No
        """
        let q = watcher.detectQuestion(from: output)
        XCTAssertNotNil(q)
        XCTAssertEqual(q?.options.count, 2)
        XCTAssertEqual(q?.selectedIndex, 0)
        XCTAssertEqual(q?.options[0], "Yes")
        XCTAssertEqual(q?.options[1], "No")
    }

    func testDetectQuestionReturnsNilForNormalOutput() {
        let watcher = makeWatcher()
        let output = """
        Building project...
        Compiling main.swift
        Linking ClawGate
        Build complete!
        """
        let q = watcher.detectQuestion(from: output)
        XCTAssertNil(q)
    }

    func testDetectQuestionReturnsNilForSingleOption() {
        let watcher = makeWatcher()
        let output = """
        ? Pick one?
          ❯ Only option
        """
        let q = watcher.detectQuestion(from: output)
        XCTAssertNil(q, "Should require at least 2 options")
    }

    func testDetectQuestionMiddleSelection() {
        let watcher = makeWatcher()
        let output = """
        ? Choose approach?
          ○ Option A
          ❯ Option B
          ○ Option C
        """
        let q = watcher.detectQuestion(from: output)
        XCTAssertNotNil(q)
        XCTAssertEqual(q?.selectedIndex, 1)
        XCTAssertEqual(q?.options[1], "Option B")
    }

    func testDetectQuestionWithBlankLinesBetweenQuestionAndOptions() {
        let watcher = makeWatcher()
        let output = """
        ? Which mode do you prefer?

          ❯ Fast
          ○ Slow
        """
        let q = watcher.detectQuestion(from: output)
        XCTAssertNotNil(q, "Should handle blank lines between question and options")
        XCTAssertEqual(q?.options.count, 2)
    }

    func testDetectQuestionIDIsPopulated() {
        let watcher = makeWatcher()
        let output = """
        ? Ready?
          ❯ Yes
          ○ No
        """
        let q = watcher.detectQuestion(from: output)
        XCTAssertNotNil(q)
        XCTAssertFalse(q!.questionID.isEmpty)
    }

    func testDetectQuestionNoQuestionMark() {
        let watcher = makeWatcher()
        let output = """
        Some heading without question mark
          ❯ Option A
          ○ Option B
        """
        let q = watcher.detectQuestion(from: output)
        XCTAssertNil(q, "Should require a line ending with ?")
    }

    // MARK: - extractSummary

    func testExtractSummaryNormalOutput() {
        let watcher = makeWatcher()
        let lines = (1...20).map { "Line \($0)" }
        let output = lines.joined(separator: "\n")
        let summary = watcher.extractSummary(from: output)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains("Line 20"))
    }

    func testExtractSummaryEmptyInput() {
        let watcher = makeWatcher()
        let summary = watcher.extractSummary(from: "")
        XCTAssertTrue(summary.isEmpty)
    }

    func testExtractSummaryTruncatesLongOutput() {
        let watcher = makeWatcher()
        let longLine = String(repeating: "A", count: 200)
        let lines = (1...100).map { "\(longLine) \($0)" }
        let output = lines.joined(separator: "\n")
        let summary = watcher.extractSummary(from: output)
        XCTAssertLessThanOrEqual(summary.count, 1000)
    }

    func testExtractSummaryCompressesBlankLines() {
        let watcher = makeWatcher()
        let output = "Line 1\n\n\n\n\n\n\n\nLine 2\n\n\n\n\nLine 3"
        let summary = watcher.extractSummary(from: output)
        // Should not have more than 2 consecutive blank entries
        let parts = summary.components(separatedBy: "\n")
        var consecutiveBlanks = 0
        var maxConsecutiveBlanks = 0
        for part in parts {
            if part.isEmpty {
                consecutiveBlanks += 1
                maxConsecutiveBlanks = max(maxConsecutiveBlanks, consecutiveBlanks)
            } else {
                consecutiveBlanks = 0
            }
        }
        XCTAssertLessThanOrEqual(maxConsecutiveBlanks, 2, "Should compress excessive blank lines")
    }
}
