import XCTest
@testable import ClawGate

final class LineVisibleContentExtractorTests: XCTestCase {
    func testCompetingClockBadgesAndAXEmbeddedDividerAreNotPromoted() {
        let rows = [row("first", 0.15, 0.7, 0.6, 0.04), row("middle", 0.15, 0.65, 0.6, 0.04),
                    row("last", 0.15, 0.6, 0.6, 0.04),
                    row("午後 1:23", 0.85, 0.59, 0.1, 0.025), row("午後 1:24", 0.85, 0.59, 0.1, 0.025)]
        let result = LineVisibleContentExtractor.extract(rows: rows)
        XCTAssertTrue(result.annotations.isEmpty)
        XCTAssertTrue(result.bodyCandidates.allSatisfy { $0.displayedTimeText == nil })
        let embedded = [row("body", 0.15, 0.7, 0.6, 0.04), row("ここから未読メッセージ", 0.4, 0.5, 0.2, 0.025),
                        row("body", 0.15, 0.3, 0.6, 0.04)]
        let grouped = LineVisibleContentExtractor.extract(rows: embedded, textBlockRegions: [.init(x: 0.1, y: 0.25, width: 0.7, height: 0.5)])
        XCTAssertTrue(grouped.annotations.isEmpty)
        XCTAssertEqual(grouped.bodyCandidates.first?.spanOrdinals, [0, 1, 2])
    }
    func testGroupsParagraphsAndAnnotatesClockBadgesAndDivider() {
        let rows = [
            row("A1", 0.15, 0.733, 0.65, 0.035), row("A2", 0.15, 0.693, 0.65, 0.035),
            row("A3", 0.15, 0.650, 0.53, 0.043), row("午前9:41", 0.858, 0.641, 0.109, 0.027),
            row("ここから未読メッセージ", 0.367, 0.559, 0.275, 0.030),
            row("B1", 0.15, 0.437, 0.64, 0.035), row("B2", 0.15, 0.393, 0.65, 0.039),
            row("B3", 0.15, 0.354, 0.65, 0.039), row("B4", 0.15, 0.320, 0.37, 0.035),
            row("午後 1:02", 0.858, 0.302, 0.121, 0.027)
        ]
        let result = LineVisibleContentExtractor.extract(rows: rows)
        XCTAssertEqual(result.bodyCandidates.count, 2)
        XCTAssertEqual(result.bodyCandidates.map(\.displayedTimeText), ["午前9:41", "午後 1:02"])
        XCTAssertEqual(result.annotations.map(\.kind), ["displayed_time", "unread_divider", "displayed_time"])
        XCTAssertTrue(result.bodyCandidates.allSatisfy { $0.sender == nil && $0.fromSelf == nil && $0.sentAt == nil })
        XCTAssertEqual((result.bodyCandidates.flatMap(\.spanOrdinals) + result.annotations.flatMap(\.spanOrdinals)).sorted(), Array(0..<10))
    }

    func testClockAndDividerLookalikesRemainText() {
        let body = [row("first", 0.15, 0.7, 0.6, 0.04), row("last", 0.15, 0.65, 0.6, 0.04)]
        for lookalike in [row("午後 99:99", 0.85, 0.64, 0.1, 0.025),
                          row("午後 1:23", 0.85, 0.74, 0.1, 0.025),
                          row("午後 1:23", 0.85, 0.64, 0.1, 0.04),
                          row("未読です", 0.4, 0.5, 0.2, 0.03),
                          row("ここから未読メッセージ", 0.4, 0.5, 0.2, 0.04)] {
            XCTAssertTrue(LineVisibleContentExtractor.extract(rows: body + [lookalike]).annotations.isEmpty)
        }
        let narrowBody = [row("first", 0.1, 0.7, 0.2, 0.04), row("last", 0.1, 0.65, 0.2, 0.04)]
        XCTAssertTrue(LineVisibleContentExtractor.extract(rows: narrowBody + [row("午後 1:23", 0.85, 0.64, 0.1, 0.025)]).annotations.isEmpty)
    }

    func testAmbiguousTimeAndColumnsRemainConservative() {
        let rows = [row("A", 0.15, 0.7, 0.3, 0.04), row("10:30", 0.20, 0.64, 0.08, 0.04), row("B", 0.70, 0.7, 0.2, 0.04)]
        let result = LineVisibleContentExtractor.extract(rows: rows)
        XCTAssertTrue(result.annotations.isEmpty)
        XCTAssertEqual(result.bodyCandidates.count, 3)
    }

    func testDuplicateTextIsNotDeduplicatedAndAXRegionsAreReused() {
        let rows = [row("same", 0.1, 0.5, 0.3, 0.04), row("same", 0.1, 0.3, 0.3, 0.04)]
        let regions = [LineObservationRect(x: 0.09, y: 0.49, width: 0.32, height: 0.06), LineObservationRect(x: 0.09, y: 0.29, width: 0.32, height: 0.06)]
        let result = LineVisibleContentExtractor.extract(rows: rows, textBlockRegions: regions)
        XCTAssertEqual(result.bodyCandidates.count, 2)
        XCTAssertEqual(result.bodyCandidates.map(\.extractionMethod), ["ax_text_block", "ax_text_block"])
    }

    private func row(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LineOCRRow {
        LineOCRRow(text: text, box: LineObservationRect(x: x, y: y, width: width, height: height))
    }
}
