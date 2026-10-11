import XCTest
@testable import ClawGate

final class AXActionsWaitPolicyTests: XCTestCase {
    func testAXWaitPolicyIsFiniteAndOrdered() {
        XCTAssertGreaterThan(AXActions.mainCallbackTimeout, 0)
        XCTAssertLessThanOrEqual(AXActions.mainCallbackTimeout, 3)
        XCTAssertGreaterThan(AXActions.reopenFallbackTimeout, 0)
        XCTAssertLessThanOrEqual(AXActions.reopenFallbackTimeout, AXActions.mainCallbackTimeout)
    }
}
