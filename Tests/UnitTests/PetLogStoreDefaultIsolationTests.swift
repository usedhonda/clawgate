import XCTest
@testable import ClawGate

/// D37: test isolation must be safe-by-construction, not convention-dependent.
/// This class deliberately does NOT redirect `PetLogStore.dir` in setUp — it
/// proves that even a case which forgets the per-test override can never resolve
/// to (or write into) the real `~/.clawgate/logs` (2026-07-14 incident class).
final class PetLogStoreDefaultIsolationTests: XCTestCase {
    func testDefaultDirIsNeverProductionUnderXCTest() {
        let def = PetLogStore.defaultDir()
        XCTAssertTrue(def.hasPrefix(NSTemporaryDirectory()),
                      "under XCTest the default store dir must live under the temp root, got \(def)")
        XCTAssertFalse(def.contains(".clawgate/logs"),
                       "the production path must be structurally unreachable under XCTest")

        let production = NSString("~/.clawgate/logs").expandingTildeInPath
        XCTAssertNotEqual(def, production)
    }

    /// A bare save (no per-case override) lands outside production. Hold the
    /// shared semaphore so a parallel class's override can't race `dir`.
    func testBareSaveLandsOutsideProduction() throws {
        PetLogStore.testIsolationSemaphore.wait()
        let saved = PetLogStore.dir
        PetLogStore.dir = PetLogStore.defaultDir()  // what a forgetful class inherits
        defer {
            try? FileManager.default.removeItem(atPath: PetLogStore.dir)
            PetLogStore.dir = saved
            PetLogStore.testIsolationSemaphore.signal()
        }
        let entry = NotificationEntry(id: "d", text: "x", source: "log", timestamp: Date())
        XCTAssertTrue(PetLogStore.save([entry], file: "log.json"))
        let written = (PetLogStore.dir as NSString).appendingPathComponent("log.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written))
        XCTAssertFalse(written.contains(".clawgate/logs"),
                       "a bare save must never target the production directory")
    }
}
