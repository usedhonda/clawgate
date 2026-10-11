import ApplicationServices
import XCTest
@testable import ClawGate

final class AXActionsWaitPolicyTests: XCTestCase {
    func testExpiredQueuedMainCallbackIsFencedBeforeItsEffect() async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 1)
        }
        let enteredExpectation = expectation(description: "main callback entered")
        DispatchQueue.global().async {
            _ = entered.wait(timeout: .now() + 1)
            enteredExpectation.fulfill()
        }
        await fulfillment(of: [enteredExpectation], timeout: 1)

        var performed = false
        let resultExpectation = expectation(description: "bounded wait returned")
        var completed = true
        DispatchQueue.global().async {
            completed = AXActions.runOnMainWithTimeoutForTesting(timeout: 0.01) { performed = true }
            resultExpectation.fulfill()
        }
        await fulfillment(of: [resultExpectation], timeout: 1)
        XCTAssertFalse(completed)
        release.signal()
        let drained = expectation(description: "expired callback drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertFalse(performed)
    }

    func testMainCallbackCompletesWhenMainQueueAvailable() async {
        var performed = false
        let resultExpectation = expectation(description: "main callback completed")
        var completed = false
        DispatchQueue.global().async {
            completed = AXActions.runOnMainWithTimeoutForTesting(timeout: 1) { performed = true }
            resultExpectation.fulfill()
        }
        await fulfillment(of: [resultExpectation], timeout: 1)
        XCTAssertTrue(completed)
        XCTAssertTrue(performed)
    }

    func testFrameReadDoesNotIssueSizeMessageAfterBudgetExpires() {
        var prepareCalls = 0
        var sizeRead = false
        var point = CGPoint(x: 10, y: 20)
        let position = AXValueCreate(.cgPoint, &point)! as CFTypeRef
        let frame = AXQuery.copyFrameFromReads(
            prepareNextRead: {
                prepareCalls += 1
                return prepareCalls == 1
            },
            readPosition: { position },
            readSize: {
                sizeRead = true
                var size = CGSize(width: 640, height: 480)
                return AXValueCreate(.cgSize, &size)
            }
        )
        XCTAssertNil(frame)
        XCTAssertFalse(sizeRead)
        XCTAssertEqual(prepareCalls, 2)
    }
}
