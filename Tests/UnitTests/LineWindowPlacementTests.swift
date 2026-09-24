import XCTest
@testable import ClawGate

/// Where ClawGate puts the LINE window. Until 2026-09-24 this arithmetic had no
/// test at all, so the numbers could be changed freely and nothing would notice
/// — including the one change that takes LINE's read path down (see the width
/// floor below).
final class LineWindowPlacementTests: XCTestCase {
    /// A 1920x1080 desktop with the menu bar out: the machine this was asked for.
    private let visible1920 = CGRect(x: 0, y: 0, width: 1920, height: 1055)

    func testTheWindowSitsTopLeftAtHalfWidthAndFullHeight() {
        let frame = AXActions.lineWindowFrame(visibleFrame: visible1920, desktopMaxY: 1080)

        XCTAssertEqual(frame.minX, 0, "hard against the left edge")
        XCTAssertEqual(frame.width, 960, "half of 1920")
        XCTAssertEqual(frame.height, 1055, "the full usable height")
        // 1080 (desktop top) - 1055 (top of the usable area) = 25, the menu bar.
        XCTAssertEqual(frame.minY, 25, "directly below the menu bar, in AX coordinates")
    }

    /// The reason the floor exists: LINE's sidebar is a fixed ~302px, so a
    /// narrow window raises its share of the width, and `LineSidebarDiscovery`
    /// rejects a sidebar past 0.35 of the window. That rejection is not a
    /// degraded selector — `resolveLineMainWindow` then finds no window at all.
    func testANarrowDisplayIsWidenedInsteadOfHalved() {
        let visible1440 = CGRect(x: 0, y: 0, width: 1440, height: 850)

        let frame = AXActions.lineWindowFrame(visibleFrame: visible1440, desktopMaxY: 900)

        XCTAssertGreaterThan(frame.width, 720, "half would be 720, which is too narrow")
        let share = AXActions.lineSidebarWidth / frame.width
        XCTAssertLessThanOrEqual(share, 0.35, "sidebar share must stay inside the discovery bound")
    }

    func testTheHalfWidthOnThisDesktopStaysInsideTheSidebarBound() {
        let frame = AXActions.lineWindowFrame(visibleFrame: visible1920, desktopMaxY: 1080)
        XCTAssertLessThanOrEqual(AXActions.lineSidebarWidth / frame.width, 0.35)
    }

    /// The floor cannot ask for more width than the display has.
    func testAVeryNarrowDisplayIsNotWidenedPastItsOwnEdge() {
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 600)

        let frame = AXActions.lineWindowFrame(visibleFrame: tiny, desktopMaxY: 600)

        XCTAssertEqual(frame.width, 800, "clamped to the display, not to the floor")
    }

    /// Regression: the flip used to divide by `NSScreen.screens.first`'s height,
    /// so when the main screen was not the primary one the window was placed
    /// off-screen. The flip is against the whole desktop.
    func testASecondaryScreenIsNotFlippedOffTheDesktop() {
        // A screen sitting above the primary one: its maxY is the desktop top.
        let secondary = CGRect(x: 0, y: 1080, width: 1920, height: 1080)

        let frame = AXActions.lineWindowFrame(visibleFrame: secondary, desktopMaxY: 2160)

        XCTAssertEqual(frame.minY, 0, "the top screen starts at the top in AX coordinates")
        XCTAssertGreaterThanOrEqual(frame.minY, 0, "never negative — that is off-screen")
    }
}
