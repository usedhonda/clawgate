import XCTest
@testable import ClawGate

final class LineHealthCaretakerTests: XCTestCase {
    func testDecisionSkipsWhileSendIsInFlight() {
        let result = LineCaretakerDecisionEngine.decide(
            LineCaretakerDecisionInput(
                isSending: true,
                sentRecently: false,
                inCooldown: false,
                lineRunning: true,
                watcherStale: true,
                surfaceAbnormal: true,
                forcedReanchorDue: true
            )
        )

        XCTAssertFalse(result.shouldRepair)
        XCTAssertEqual(result.assessmentReason, "recent_send_guard")
        XCTAssertNil(result.mode)
    }

    func testDecisionUsesRecoverIfNeededForWatcherStale() {
        let result = LineCaretakerDecisionEngine.decide(
            LineCaretakerDecisionInput(
                isSending: false,
                sentRecently: false,
                inCooldown: false,
                lineRunning: true,
                watcherStale: true,
                surfaceAbnormal: false,
                forcedReanchorDue: false
            )
        )

        XCTAssertTrue(result.shouldRepair)
        XCTAssertEqual(result.mode, .recoverIfNeeded)
        XCTAssertEqual(result.repairReason, "watcher_stale")
    }

    func testDecisionUsesForceRecoverForForcedReanchor() {
        let result = LineCaretakerDecisionEngine.decide(
            LineCaretakerDecisionInput(
                isSending: false,
                sentRecently: false,
                inCooldown: false,
                lineRunning: true,
                watcherStale: false,
                surfaceAbnormal: false,
                forcedReanchorDue: true
            )
        )

        XCTAssertTrue(result.shouldRepair)
        XCTAssertEqual(result.mode, .forceRecover)
        XCTAssertEqual(result.repairReason, "forced_reanchor_due")
    }

    func testDecisionDefersDuringCooldown() {
        let result = LineCaretakerDecisionEngine.decide(
            LineCaretakerDecisionInput(
                isSending: false,
                sentRecently: false,
                inCooldown: true,
                lineRunning: true,
                watcherStale: true,
                surfaceAbnormal: true,
                forcedReanchorDue: false
            )
        )

        XCTAssertFalse(result.shouldRepair)
        XCTAssertEqual(result.assessmentReason, "cooldown_active")
    }
}
