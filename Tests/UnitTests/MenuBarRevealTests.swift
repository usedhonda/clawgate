import XCTest
@testable import ClawGate

final class MenuBarRevealTests: XCTestCase {
    func testVisibleFrontmostPanelCloses() {
        XCTAssertTrue(MenuBarPanelRevealPolicy.shouldCloseVisiblePanel(
            isVisible: true,
            isKeyWindow: true,
            applicationIsActive: false
        ))
        XCTAssertTrue(MenuBarPanelRevealPolicy.shouldCloseVisiblePanel(
            isVisible: true,
            isKeyWindow: false,
            applicationIsActive: true
        ))
    }

    func testVisiblePanelBehindAnotherAppIsRevealed() {
        XCTAssertFalse(MenuBarPanelRevealPolicy.shouldCloseVisiblePanel(
            isVisible: true,
            isKeyWindow: false,
            applicationIsActive: false
        ))
        XCTAssertFalse(MenuBarPanelRevealPolicy.shouldCloseVisiblePanel(
            isVisible: false,
            isKeyWindow: true,
            applicationIsActive: true
        ))
    }
}
