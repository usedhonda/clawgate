import XCTest
@testable import ClawGate

final class MenuBarRevealTests: XCTestCase {
    func testVisibleFrontmostPanelCloses() {
        XCTAssertTrue(MenuBarPanelRevealPolicy.shouldCloseVisiblePanel(
            isVisible: true,
            isKeyWindow: true
        ))
        XCTAssertTrue(MenuBarPanelRevealPolicy.shouldCloseVisiblePanel(
            isVisible: true,
            isKeyWindow: true
        ))
    }

    func testVisiblePanelBehindAnotherAppIsRevealed() {
        XCTAssertFalse(MenuBarPanelRevealPolicy.shouldCloseVisiblePanel(
            isVisible: true,
            isKeyWindow: false
        ))
        XCTAssertFalse(MenuBarPanelRevealPolicy.shouldCloseVisiblePanel(
            isVisible: false,
            isKeyWindow: true
        ))
    }

    func testActivationTransitionDoesNotCloseNonKeyPanel() {
        XCTAssertFalse(MenuBarPanelRevealPolicy.shouldCloseVisiblePanel(
            isVisible: true,
            isKeyWindow: false
        ))
    }
}
