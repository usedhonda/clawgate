import XCTest
@testable import ClawGate

final class MenuBarStatusItemPlacementTests: XCTestCase {
    func testMissingPositionStartsOnRight() {
        XCTAssertEqual(MenuBarStatusItemPlacement.preferredPosition(savedPosition: nil, rightSideWidth: 600), 0)
    }

    func testUsablePositionIsPreserved() {
        XCTAssertEqual(MenuBarStatusItemPlacement.preferredPosition(savedPosition: 180, rightSideWidth: 600), 180)
    }

    func testLeftSidePositionMovesRight() {
        XCTAssertEqual(MenuBarStatusItemPlacement.preferredPosition(savedPosition: 800, rightSideWidth: 600), 0)
        XCTAssertEqual(MenuBarStatusItemPlacement.preferredPosition(savedPosition: 600, rightSideWidth: 600), 0)
    }

    func testNotchNarrowsUsableRightSide() {
        XCTAssertEqual(MenuBarStatusItemPlacement.preferredPosition(savedPosition: 500, rightSideWidth: 400), 0)
    }

    func testInvalidPositionsMoveRight() {
        for position in [-1, Double.nan, Double.infinity] {
            XCTAssertEqual(MenuBarStatusItemPlacement.preferredPosition(savedPosition: position, rightSideWidth: 600), 0)
        }
    }
}
