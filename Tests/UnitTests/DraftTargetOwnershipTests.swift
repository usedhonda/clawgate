import XCTest
import AppKit
@testable import ClawGate

final class DraftTargetOwnershipTests: XCTestCase {
    private let target = AXAppWindow.WindowIdentity(
        pid: 101,
        bundleIdentifier: "com.example.editor",
        windowIdentifier: "main-window",
        frame: CGRect(x: 20, y: 30, width: 800, height: 600),
        title: "Draft"
    )

    func testExactPidWindowAndFocusAreRequiredBeforeActivationOrPaste() {
        let mismatches = [
            target.with(pid: 202),
            target.with(windowIdentifier: "other-window"),
            target.with(frame: CGRect(x: 21, y: 30, width: 800, height: 600)),
            target.with(title: "Other"),
        ]

        for mismatch in mismatches {
            var activateCount = 0
            var pasteCount = 0
            let result = DraftPlacer.attemptPlacementForTesting(
                target: target,
                current: mismatch,
                frontmostPID: target.pid,
                focused: true,
                minimized: false,
                activate: { activateCount += 1 },
                paste: { pasteCount += 1 }
            )

            XCTAssertEqual(result, .fallback)
            XCTAssertEqual(activateCount, 0)
            XCTAssertEqual(pasteCount, 0)
        }
    }

    func testFocusChangeReturnsFallbackWithoutActivationOrPaste() {
        var activateCount = 0
        var pasteCount = 0
        let result = DraftPlacer.attemptPlacementForTesting(
            target: target,
            current: target,
            frontmostPID: 202,
            focused: false,
            minimized: false,
            activate: { activateCount += 1 },
            paste: { pasteCount += 1 }
        )

        XCTAssertEqual(result, .fallback)
        XCTAssertEqual(activateCount, 0)
        XCTAssertEqual(pasteCount, 0)
    }

    func testMatchingTargetAllowsExactlyOnePlacementAttempt() {
        var activateCount = 0
        var pasteCount = 0
        let result = DraftPlacer.attemptPlacementForTesting(
            target: target,
            current: target,
            frontmostPID: target.pid,
            focused: true,
            minimized: false,
            activate: { activateCount += 1 },
            paste: { pasteCount += 1 }
        )

        XCTAssertEqual(result, .placed)
        XCTAssertEqual(activateCount, 1)
        XCTAssertEqual(pasteCount, 1)
    }

    func testSurfaceFailureDoesNotReportSuccess() {
        XCTAssertFalse(AXActions.surfaceResultForTesting(directSucceeded: false, fallbackSucceeded: false))
        XCTAssertTrue(AXActions.surfaceResultForTesting(directSucceeded: false, fallbackSucceeded: true))
        XCTAssertTrue(AXActions.surfaceResultForTesting(directSucceeded: true, fallbackSucceeded: false))
    }
}

private extension AXAppWindow.WindowIdentity {
    func with(
        pid: pid_t? = nil,
        windowIdentifier: String? = nil,
        frame: CGRect? = nil,
        title: String? = nil
    ) -> Self {
        Self(
            pid: pid ?? self.pid,
            bundleIdentifier: bundleIdentifier,
            windowIdentifier: windowIdentifier ?? self.windowIdentifier,
            frame: frame ?? self.frame,
            title: title ?? self.title
        )
    }
}
