import XCTest
@testable import ClawGate

/// D162/A3-21: the shared test-isolation primitive. Every XCTestCase that
/// overrides a process-global static (`PetLogStore.dir`, `PetModel` timeouts)
/// routes its setUp/tearDown through this, so the "mutate the static before /
/// without holding the isolation semaphore" ordering — which lets a parallel
/// test class momentarily observe another class's override mid-test — is not
/// representable: the override closure can only run AFTER the `wait()`.
enum PetLogTestIsolation {
    final class Token {
        private var released = false
        private let restore: () -> Void
        fileprivate init(restore: @escaping () -> Void) { self.restore = restore }
        /// Restore the overridden statics, then release the isolation semaphore.
        /// Idempotent so a double tearDown cannot over-signal the semaphore.
        func release() {
            guard !released else { return }
            released = true
            restore()
            PetLogStore.testIsolationSemaphore.signal()
        }
    }

    /// Acquire the process-global isolation semaphore, THEN run `overriding` (the
    /// static overrides) inside the held critical section, and return a token
    /// whose `release()` restores + signals in tearDown.
    static func acquire(overriding mutate: () -> Void, restoring restore: @escaping () -> Void) -> Token {
        PetLogStore.testIsolationSemaphore.wait()
        mutate()
        return Token(restore: restore)
    }
}

final class PetLogTestIsolationOrderingTests: XCTestCase {
    /// D162/A3-21 old-fail guard: the override must run ONLY after the semaphore
    /// is held. A non-blocking `wait(timeout: .now())` inside the override, on the
    /// same non-reentrant semaphore, returns `.timedOut` iff we already hold it
    /// (correct wait→mutate ordering). Under the old "mutate before wait" ordering
    /// the semaphore would still be free, so the inner wait would return
    /// `.success` — this assertion fails, which is the regression guard.
    func testAcquireRunsOverrideOnlyWhileIsolationHeld() {
        var observed: DispatchTimeoutResult = .success
        let token = PetLogTestIsolation.acquire(overriding: {
            observed = PetLogStore.testIsolationSemaphore.wait(timeout: .now())
            // If we accidentally took the lock (the bug), give it back so the
            // count is balanced before release() signals.
            if observed == .success { PetLogStore.testIsolationSemaphore.signal() }
        }, restoring: {})
        token.release()
        XCTAssertEqual(observed, .timedOut,
            "acquire(overriding:) must hold testIsolationSemaphore before running the override closure (D162/A3-21)")
    }
}
