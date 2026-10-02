import XCTest
@testable import ClawGate

final class LineBodyCandidateExtractorTests: XCTestCase {
    func testGroupsMultilineOnlyInsideExplicitBlock() {
        let rows = [row("alpha", 0.20, 0.70), row("beta", 0.20, 0.60)]
        let candidates = LineBodyCandidateExtractor.extract(rows: rows,
                                                              textBlockRegions: [rect(0.19, 0.59, 0.4, 0.23)])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].text, "alpha\nbeta")
        XCTAssertEqual(candidates[0].spanOrdinals, [0, 1])
        XCTAssertEqual(candidates[0].extractionMethod, "ax_text_block")
        XCTAssertEqual(candidates[0].coverage, "visible_fragment")
    }

    func testNearbyDistinctBlocksRemainDistinct() {
        let rows = [row("one", 0.10, 0.70), row("two", 0.30, 0.70)]
        let candidates = LineBodyCandidateExtractor.extract(rows: rows,
                                                              textBlockRegions: [rect(0.09, 0.69, 0.14, 0.08), rect(0.29, 0.69, 0.14, 0.08)],
                                                              regionMethod: "ax_history_row")
        XCTAssertEqual(candidates.map(\.text), ["one", "two"])
        XCTAssertEqual(candidates.map(\.spanOrdinals), [[0], [1]])
        XCTAssertEqual(candidates.map(\.extractionMethod), ["ax_history_row", "ax_history_row"])
    }

    func testIdenticalRepeatsArePreserved() {
        let rows = [row("repeat", 0.1, 0.8), row("repeat", 0.1, 0.5)]
        let candidates = LineBodyCandidateExtractor.extract(rows: rows)
        XCTAssertEqual(candidates.map(\.text), ["repeat", "repeat"])
        XCTAssertEqual(candidates.map(\.ordinal), [0, 1])
    }

    func testOverlappingRegionsFallBackToSingleSpans() {
        let rows = [row("first", 0.2, 0.7), row("second", 0.2, 0.6)]
        let regions = [rect(0.19, 0.59, 0.4, 0.23), rect(0.2, 0.59, 0.4, 0.23)]
        let candidates = LineBodyCandidateExtractor.extract(rows: rows, textBlockRegions: regions)
        XCTAssertEqual(candidates.map(\.text), ["first", "second"])
        XCTAssertTrue(candidates.allSatisfy { $0.spanOrdinals.count == 1 })
    }

    func testMissingRegionsAndUnknownFieldsRemainConservative() throws {
        let candidates = LineBodyCandidateExtractor.extract(rows: [row("visible", 0.1, 0.4)])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates[0].sender)
        XCTAssertNil(candidates[0].fromSelf)
        XCTAssertNil(candidates[0].sentAt)
        XCTAssertEqual(candidates[0].sentAtPrecision, "unknown")
        XCTAssertNil(candidates[0].displayedTimeText)
        XCTAssertEqual(candidates[0].coverage, "visible_fragment")

        let decoded = try JSONDecoder().decode(LineBodyCandidate.self,
                                                from: JSONEncoder().encode(candidates[0]))
        XCTAssertEqual(decoded, candidates[0])
    }

    func testInvalidGeometryCannotCreateEvidenceCandidates() {
        let rows = [row("valid", 0.1, 0.2), row("outside", -0.1, 0.2), row("nonfinite", .nan, 0.2)]
        XCTAssertEqual(LineBodyCandidateExtractor.extract(rows: rows).map(\.spanOrdinals), [[0]])
    }

    private func row(_ text: String, _ x: Double, _ y: Double) -> LineOCRRow {
        LineOCRRow(text: text, box: rect(x, y, 0.12, 0.05))
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LineObservationRect {
        LineObservationRect(x: x, y: y, width: width, height: height)
    }
}
