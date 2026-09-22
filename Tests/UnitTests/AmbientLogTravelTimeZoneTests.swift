import XCTest
@testable import ClawGate

/// The owner of this Mac travels constantly, so the Log's timezone is not a
/// launch-time constant — it is whatever the Mac says right now. `AmbientLogModel`
/// used to capture `TimeZone.current` in a `let`, and since the model lives as
/// long as the app, the Log kept showing the departure city's clock until the
/// next restart.
///
/// The zone is injected here rather than set process-wide, so these tests move
/// the Mac without disturbing any other suite.
final class AmbientLogTravelTimeZoneTests: XCTestCase {
    private var tmpRoot: URL!
    /// The Mac's current zone, as these tests move it.
    private var zone = TimeZone(identifier: "Asia/Singapore")!

    override func setUpWithError() throws {
        PetLogStore.testIsolationSemaphore.wait()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawgate-log-travel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        PetLogStore.testIsolationSemaphore.signal()
    }

    /// `load()` scans storage and writes provenance sidecars, so every model in
    /// this file is pointed at a temp root (2026-07-14: a test wrote into the
    /// owner's real data).
    private func model() -> AmbientLogModel {
        let m = AmbientLogModel(zoneProvider: { [weak self] in
            self?.zone ?? .current
        })
        m.sessionsRootOverrideForTesting = tmpRoot
        return m
    }

    private func setZone(_ identifier: String) {
        zone = TimeZone(identifier: identifier)!
    }

    func testTheLogsZoneFollowsTheMacAfterTheOwnerTravels() throws {
        setZone("Asia/Singapore")
        let model = self.model()
        XCTAssertEqual(model.timeZoneForTesting.identifier, "Asia/Singapore")

        // The owner lands somewhere else while the app keeps running.
        setZone("Asia/Kolkata")

        XCTAssertEqual(model.timeZoneForTesting.identifier, "Asia/Kolkata",
                       "the Log must read the Mac's zone at use, not at launch")
    }

    func testTheSelectedDayIsReAnchoredWhenTheZoneChangesWhileViewingToday() throws {
        setZone("Asia/Singapore")
        let model = self.model()
        let before = model.selectedDay

        setZone("Pacific/Auckland")
        model.systemZoneChangedForTesting()

        XCTAssertNotEqual(model.selectedDay, before,
                          "today's start moves when the zone does")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        XCTAssertEqual(model.selectedDay, cal.startOfDay(for: Date()))
    }

    func testADeliberatelyChosenPastDayIsNotReAnchored() throws {
        setZone("Asia/Singapore")
        let model = self.model()
        model.moveDay(by: -5)
        let chosen = model.selectedDay

        var before = Calendar(identifier: .gregorian)
        before.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let chosenDate = before.dateComponents([.year, .month, .day], from: chosen)

        setZone("Asia/Kolkata")
        model.systemZoneChangedForTesting()

        // The same calendar date, now expressed in the new zone — not the same
        // instant, which would slide the Log to the previous day.
        var after = Calendar(identifier: .gregorian)
        after.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        XCTAssertEqual(after.dateComponents([.year, .month, .day], from: model.selectedDay),
                       chosenDate,
                       "a past day the owner picked stays that date across a flight")
        XCTAssertEqual(model.selectedDay, after.startOfDay(for: model.selectedDay))
    }
}
