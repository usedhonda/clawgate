import XCTest
@testable import ClawGate

final class MenuBarRevealTests: XCTestCase {
    func testOnlyVisibleKeyPanelCloses() {
        let cases: [(visible: Bool, key: Bool, closes: Bool)] = [
            (true, true, true),
            (true, false, false),
            (false, true, false),
            (false, false, false),
        ]
        for row in cases {
            XCTAssertEqual(
                MenuBarPanelRevealPolicy.shouldCloseVisiblePanel(
                    isVisible: row.visible,
                    isKeyWindow: row.key
                ),
                row.closes,
                "visible=\(row.visible), key=\(row.key)"
            )
        }
    }
}
