import XCTest
@testable import ClawGate

final class RetryPolicyTests: XCTestCase {

    private struct TestError: Error, Equatable {
        let message: String
    }

    func testSuccessOnFirstAttempt() throws {
        let policy = RetryPolicy(maxAttempts: 3, initialDelayMs: 0)
        var callCount = 0

        let result = try policy.run {
            callCount += 1
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 1)
    }

    func testThrowsAfterMaxAttempts() {
        let policy = RetryPolicy(maxAttempts: 3, initialDelayMs: 0)
        var callCount = 0

        XCTAssertThrowsError(try policy.run {
            callCount += 1
            throw TestError(message: "fail")
        }) { error in
            XCTAssertEqual(error as? TestError, TestError(message: "fail"))
        }

        XCTAssertEqual(callCount, 3)
    }

    func testSucceedsOnNthAttempt() throws {
        let policy = RetryPolicy(maxAttempts: 3, initialDelayMs: 0)
        var callCount = 0

        let result = try policy.run {
            callCount += 1
            if callCount < 2 {
                throw TestError(message: "transient")
            }
            return "recovered"
        }

        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(callCount, 2)
    }

    func testMaxAttemptsClampedToMinimumOne() throws {
        let policy = RetryPolicy(maxAttempts: 0, initialDelayMs: 0)
        var callCount = 0

        XCTAssertThrowsError(try policy.run {
            callCount += 1
            throw TestError(message: "fail")
        })

        XCTAssertEqual(callCount, 1, "maxAttempts=0 should be clamped to 1")
    }

    func testLastErrorIsPropagated() {
        let policy = RetryPolicy(maxAttempts: 2, initialDelayMs: 0)
        var callCount = 0

        XCTAssertThrowsError(try policy.run {
            callCount += 1
            throw TestError(message: "error-\(callCount)")
        }) { error in
            XCTAssertEqual((error as? TestError)?.message, "error-2",
                           "Should throw the last error, not the first")
        }
    }
}
