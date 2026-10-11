import XCTest
@testable import ClawGate

final class AXActionsWaitPolicyTests: XCTestCase {
    func testAXWaitPolicyIsFiniteAndOrdered() {
        XCTAssertGreaterThan(AXActions.mainCallbackTimeout, 0)
        XCTAssertLessThanOrEqual(AXActions.mainCallbackTimeout, 3)
        XCTAssertGreaterThan(AXActions.reopenFallbackTimeout, 0)
        XCTAssertLessThanOrEqual(AXActions.reopenFallbackTimeout, AXActions.mainCallbackTimeout)
    }

    func testExpiredQueuedMainCallbackIsFencedBeforeItsEffect() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            entered.signal()
            release.wait()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        var performed = false
        let completed = DispatchQueue.global().sync {
            AXActions.runOnMainWithTimeoutForTesting(timeout: 0.01) { performed = true }
        }
        XCTAssertFalse(completed)
        release.signal()
        DispatchQueue.main.sync { }
        XCTAssertFalse(performed)
    }

    func testMainCallbackCompletesWhenMainQueueAvailable() {
        var performed = false
        let completed = DispatchQueue.global().sync {
            AXActions.runOnMainWithTimeoutForTesting(timeout: 1) { performed = true }
        }
        XCTAssertTrue(completed)
        XCTAssertTrue(performed)
    }
}
