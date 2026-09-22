import XCTest
@testable import ClawGate

/// `JevBreaker` is a pure, non-latching decision: it opens only when the
/// most recent three attempts were all failures, and only for 30 minutes.
final class JevBreakerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeBreaker() -> (JevBreaker, UserDefaults, String) {
        let suite = "clawgate.tests.jev.breaker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (JevBreaker(defaults: defaults), defaults, suite)
    }

    func testNoAttemptsNeverSkips() {
        let (breaker, defaults, suite) = makeBreaker()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(breaker.shouldSkip(now: now))
    }

    func testTwoFailuresDoNotOpenTheBreaker() {
        var (breaker, defaults, suite) = makeBreaker()
        defer { defaults.removePersistentDomain(forName: suite) }
        breaker.record(ok: false, at: now)
        breaker.record(ok: false, at: now.addingTimeInterval(60))
        XCTAssertFalse(breaker.shouldSkip(now: now.addingTimeInterval(61)))
    }

    func testThreeConsecutiveFailuresWithinThirtyMinutesSkips() {
        var (breaker, defaults, suite) = makeBreaker()
        defer { defaults.removePersistentDomain(forName: suite) }
        breaker.record(ok: false, at: now)
        breaker.record(ok: false, at: now.addingTimeInterval(60))
        breaker.record(ok: false, at: now.addingTimeInterval(120))
        XCTAssertTrue(breaker.shouldSkip(now: now.addingTimeInterval(121)))
    }

    func testThreeFailuresButTheLatestIsThirtyOneMinutesOldDoesNotSkip() {
        var (breaker, defaults, suite) = makeBreaker()
        defer { defaults.removePersistentDomain(forName: suite) }
        breaker.record(ok: false, at: now)
        breaker.record(ok: false, at: now.addingTimeInterval(60))
        breaker.record(ok: false, at: now.addingTimeInterval(120))
        let later = now.addingTimeInterval(120 + 31 * 60)
        XCTAssertFalse(breaker.shouldSkip(now: later))
    }

    func testFailuresThenASuccessReopensTheBreaker() {
        var (breaker, defaults, suite) = makeBreaker()
        defer { defaults.removePersistentDomain(forName: suite) }
        breaker.record(ok: false, at: now)
        breaker.record(ok: false, at: now.addingTimeInterval(60))
        breaker.record(ok: false, at: now.addingTimeInterval(120))
        breaker.record(ok: true, at: now.addingTimeInterval(180))
        XCTAssertFalse(breaker.shouldSkip(now: now.addingTimeInterval(181)))
    }

    func testRecordingKeepsAtMostFiftyAttempts() {
        var (breaker, defaults, suite) = makeBreaker()
        defer { defaults.removePersistentDomain(forName: suite) }
        for i in 0..<60 {
            breaker.record(ok: false, at: now.addingTimeInterval(Double(i)))
        }
        let raw = defaults.array(forKey: "clawgate.jev.breaker") as? [[String: Any]]
        XCTAssertEqual(raw?.count, JevBreaker.maxKept)
    }

    func testStateRoundTripsThroughUserDefaults() {
        let suite = "clawgate.tests.jev.breaker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var writer = JevBreaker(defaults: defaults)
        writer.record(ok: false, at: now)
        writer.record(ok: false, at: now.addingTimeInterval(60))
        writer.record(ok: false, at: now.addingTimeInterval(120))

        // A freshly-constructed breaker over the same defaults suite must see
        // the same persisted state — nothing here is held only in memory.
        let reader = JevBreaker(defaults: defaults)
        XCTAssertTrue(reader.shouldSkip(now: now.addingTimeInterval(121)))
    }
}
