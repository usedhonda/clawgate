import XCTest
@testable import ClawGate

final class LinePassiveCaptureTests: XCTestCase {
    func testScreenGeometryMapsToWindowPixelsAndRejectsOverlappingComposer() {
        let window = CGRect(x: 800, y: 300, width: 600, height: 700)
        let history = CGRect(x: 820, y: 370, width: 560, height: 400)
        let composer = CGRect(x: 820, y: 780, width: 560, height: 180)
        XCTAssertEqual(LinePassiveCapture.pixelCrop(content: history, window: window, imageWidth: 1200, imageHeight: 1400),
                       CGRect(x: 40, y: 140, width: 1120, height: 800))
        XCTAssertEqual(LinePassiveCapture.safeContentFrame(lists: [history], excluded: [composer], window: window), history)
        let expandedDraft = CGRect(x: 820, y: 700, width: 560, height: 260)
        XCTAssertNil(LinePassiveCapture.safeContentFrame(lists: [history], excluded: [expandedDraft], window: window))
    }
    func testUnknownWindowIsNotPromotedByWidthOrText() {
        XCTAssertEqual(LinePassiveCapture.structuralKind(hasList: false, hasSearch: true, hasComposer: false), .unknown)
        XCTAssertEqual(LinePassiveCapture.structuralKind(hasList: true, hasSearch: false, hasComposer: true), .conversation)
        XCTAssertEqual(LinePassiveCapture.structuralKind(hasList: true, hasSearch: true, hasComposer: false), .sidebar)
    }
    func testRowsRetainUnknownDirectionAndTimestamp() throws {
        let row = LineOCRRow(text: "sample", box: LineObservationRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1), confidence: 0.9)
        let decoded = try JSONDecoder().decode(LineOCRRow.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(decoded, row)
        XCTAssertEqual(decoded.direction, .unknown)
        XCTAssertNil(decoded.timestamp)
    }
}
