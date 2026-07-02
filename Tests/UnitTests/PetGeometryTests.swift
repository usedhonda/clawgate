import XCTest
@testable import ClawGate

/// Characterization tests for PetGeometry — the pure coordinate helpers
/// extracted from PetModel (TD-11). Headless-safe: the y-flip takes an explicit
/// `desktopMaxY`, so no NSScreen is required. Expected values are derived from
/// the formulas, not copied from runtime output.
final class PetGeometryTests: XCTestCase {

    // MARK: - roughlySameFrame (default tolerance = 20, strict <)

    func testRoughlySameFrameIdenticalRects() {
        XCTAssertTrue(PetGeometry.roughlySameFrame(CGRect(x: 0, y: 0, width: 100, height: 100),
                                                   CGRect(x: 0, y: 0, width: 100, height: 100)))
    }

    func testRoughlySameFrameWithinDefaultTolerance() {
        // x differs by 19 (< 20) -> still "same"
        XCTAssertTrue(PetGeometry.roughlySameFrame(CGRect(x: 0, y: 0, width: 100, height: 100),
                                                   CGRect(x: 19, y: 0, width: 100, height: 100)))
        // height differs by 15 (< 20)
        XCTAssertTrue(PetGeometry.roughlySameFrame(CGRect(x: 0, y: 0, width: 100, height: 100),
                                                   CGRect(x: 0, y: 0, width: 100, height: 115)))
    }

    func testRoughlySameFrameBoundaryIsStrictlyLessThan() {
        // exactly 20 -> abs(...) < 20 is false -> NOT same
        XCTAssertFalse(PetGeometry.roughlySameFrame(CGRect(x: 0, y: 0, width: 100, height: 100),
                                                    CGRect(x: 20, y: 0, width: 100, height: 100)))
    }

    func testRoughlySameFrameOverToleranceOnAnyDimension() {
        // x over
        XCTAssertFalse(PetGeometry.roughlySameFrame(CGRect(x: 0, y: 0, width: 100, height: 100),
                                                    CGRect(x: 21, y: 0, width: 100, height: 100)))
        // width over
        XCTAssertFalse(PetGeometry.roughlySameFrame(CGRect(x: 0, y: 0, width: 100, height: 100),
                                                    CGRect(x: 0, y: 0, width: 130, height: 100)))
    }

    func testRoughlySameFrameCustomToleranceIsRespected() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 15, y: 0, width: 100, height: 100)
        XCTAssertFalse(PetGeometry.roughlySameFrame(a, b, tolerance: 10)) // 15 not < 10
        XCTAssertTrue(PetGeometry.roughlySameFrame(a, b, tolerance: 20))  // 15 < 20
    }

    // MARK: - appKitRect(forTrackedFrame:desktopMaxY:) — y flip only

    func testAppKitRectFlipsYAgainstDesktopMaxY() {
        // y_flipped = desktopMaxY - origin.y - height = 1000 - 0 - 50 = 950
        let result = PetGeometry.appKitRect(forTrackedFrame: CGRect(x: 0, y: 0, width: 100, height: 50),
                                            desktopMaxY: 1000)
        XCTAssertEqual(result, CGRect(x: 0, y: 950, width: 100, height: 50))
    }

    func testAppKitRectPassesXWidthHeightThroughUnchanged() {
        // y_flipped = 800 - 200 - 40 = 560; x/width/height untouched
        let result = PetGeometry.appKitRect(forTrackedFrame: CGRect(x: 10, y: 200, width: 30, height: 40),
                                            desktopMaxY: 800)
        XCTAssertEqual(result, CGRect(x: 10, y: 560, width: 30, height: 40))
    }

    func testAppKitRectHandlesFrameAboveOrigin() {
        // Secondary display above main: negative tracked y.
        // y_flipped = 1200 - (-300) - 100 = 1400
        let result = PetGeometry.appKitRect(forTrackedFrame: CGRect(x: 0, y: -300, width: 100, height: 100),
                                            desktopMaxY: 1200)
        XCTAssertEqual(result, CGRect(x: 0, y: 1400, width: 100, height: 100))
    }

    func testAppKitRectFlipIsItsOwnInverse() {
        // Applying the flip twice with the same desktopMaxY returns the original.
        let original = CGRect(x: 12, y: 34, width: 56, height: 78)
        let once = PetGeometry.appKitRect(forTrackedFrame: original, desktopMaxY: 900)
        let twice = PetGeometry.appKitRect(forTrackedFrame: once, desktopMaxY: 900)
        XCTAssertEqual(twice, original)
    }
}
