import XCTest
@testable import ClawGate

/// D39: a partial drop (or whole-file corruption) at load must surface as a
/// durable, user-facing recovery warning through the real restore path — not be
/// silently treated as a normal load. The warning persists across a save and
/// across a restart until the user acknowledges it.
final class PetLogRecoveryWarningTests: XCTestCase {
    private var originalDir = ""

    override func setUp() {
        super.setUp()
        PetLogStore.testIsolationSemaphore.wait()
        originalDir = PetLogStore.dir
        PetLogStore.dir = NSTemporaryDirectory() + "clawgate-test-logs-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: PetLogStore.dir, withIntermediateDirectories: true)
        PetLogStore.resetPoisonedForTesting()
        PetLogStore.applyPermissionsHookForTesting = nil
    }

    override func tearDown() {
        PetLogStore.applyPermissionsHookForTesting = nil
        try? FileManager.default.removeItem(atPath: PetLogStore.dir)
        PetLogStore.resetPoisonedForTesting()
        PetLogStore.dir = originalDir
        PetLogStore.testIsolationSemaphore.signal()
        super.tearDown()
    }

    private func path(_ file: String) -> String {
        (PetLogStore.dir as NSString).appendingPathComponent(file)
    }

    private func mode(_ file: String) throws -> Int16? {
        (try FileManager.default.attributesOfItem(atPath: path(file))[.posixPermissions] as? NSNumber)?.int16Value
    }

    /// Full D39 lifecycle: partial-drop fixture -> restore surfaces a durable
    /// warning while keeping the good entries -> an append does not clear it ->
    /// a simulated restart still shows it -> acknowledge clears it for good.
    func testPartialDropSurfacesDurableWarningThroughRestorePath() throws {
        // One good + one undecodable entry in log.json.
        let json = """
        [{"id":"g1","text":"good one","source":"log","timestamp":"2026-08-09T00:00:00Z"},
         {"unexpected":"shape"}]
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: path("log.json")))

        let model = PetModel()
        model.restorePersistedLogsForTesting()

        // Good entries are kept and shown...
        XCTAssertEqual(model.logReplies.map(\.text), ["good one"], "the decodable entry must survive")
        // ...and the drop is surfaced as a durable warning (not a conversation entry).
        guard let warning = model.logRecoveryWarnings.first(where: { $0.file == "log.json" }) else {
            return XCTFail("a recovery warning must be raised for the partial drop")
        }
        XCTAssertEqual(warning.kind, "partialDrop")
        XCTAssertEqual(warning.droppedCount, 1)
        XCTAssertNotNil(warning.quarantine, "the warning must reference the quarantine copy")
        XCTAssertFalse(model.logReplies.contains { $0.text.contains("recovery") || $0.text.contains("warning") },
                       "the warning must never appear as a ちー conversation entry")

        // The quarantined original is preserved, owner-only, byte-identical.
        let quarantineName = warning.quarantine!
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path(quarantineName))), originalBytes)
        XCTAssertEqual(try mode(quarantineName), 0o600)

        // An append (real persist path) must NOT clear the warning.
        model.addSummonResult(text: "a new arrival", source: "log", parseAsStructured: false)
        XCTAssertTrue(model.logReplies.contains { $0.text == "a new arrival" }, "append must persist")
        XCTAssertTrue(model.logRecoveryWarnings.contains { $0.file == "log.json" },
                      "the warning must survive an append/save")

        // A simulated restart (fresh model, same dir) still shows the warning —
        // it was persisted to recovery-warnings.json.
        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()
        XCTAssertTrue(restarted.logRecoveryWarnings.contains { $0.file == "log.json" },
                      "the warning must persist across a restart")

        // Acknowledge clears it, durably.
        restarted.acknowledgeLogRecoveryWarnings()
        XCTAssertTrue(restarted.logRecoveryWarnings.isEmpty)
        let afterAck = PetModel()
        afterAck.restorePersistedLogsForTesting()
        XCTAssertTrue(afterAck.logRecoveryWarnings.isEmpty, "acknowledged warnings must not come back")
    }

    /// Whole-file corruption surfaces through the same durable warning mechanism.
    func testCorruptFileSurfacesDurableWarning() throws {
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: path("summon.json")))

        let model = PetModel()
        model.restorePersistedLogsForTesting()

        guard let warning = model.logRecoveryWarnings.first(where: { $0.file == "summon.json" }) else {
            return XCTFail("a corrupt file must raise a recovery warning")
        }
        XCTAssertEqual(warning.kind, "corrupt")
        XCTAssertNotNil(warning.quarantine)
    }

    /// A load-time permission convergence failure surfaces as a durable security
    /// warning through the restore path, without touching bytes.
    func testLoadPermissionFailureSurfacesSecurityWarning() throws {
        let json = """
        [{"id":"g","text":"kept","source":"log","timestamp":"2026-08-09T00:00:00Z"}]
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let before = try Data(contentsOf: URL(fileURLWithPath: path("log.json")))

        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }

        let model = PetModel()
        model.restorePersistedLogsForTesting()

        XCTAssertEqual(model.logReplies.map(\.text), ["kept"], "content still loads")
        guard let warning = model.logRecoveryWarnings.first(where: { $0.file == "log.json" }) else {
            return XCTFail("a load-time chmod failure must raise a security warning")
        }
        XCTAssertEqual(warning.kind, "insecurePermissions")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("log.json"))), before,
                       "bytes must be untouched by the failed permission convergence")
    }
}
