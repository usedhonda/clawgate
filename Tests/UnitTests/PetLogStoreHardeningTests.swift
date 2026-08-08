import XCTest
@testable import ClawGate

/// D9: PetLogStore load hardening. Guards the production data-loss path where a
/// single undecodable `log.json` was silently flattened to `[]`, then the next
/// append atomically overwrote the real history with `[]` + one new entry.
final class PetLogStoreHardeningTests: XCTestCase {
    private var originalDir = ""

    override func setUp() {
        super.setUp()
        // `dir` and the poisoned set are process-global statics — hold the
        // shared semaphore for the whole test lifetime so a parallel test in
        // another class can't race the override.
        PetLogStore.testIsolationSemaphore.wait()
        originalDir = PetLogStore.dir
        PetLogStore.dir = NSTemporaryDirectory() + "clawgate-test-logs-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: PetLogStore.dir, withIntermediateDirectories: true)
        PetLogStore.resetPoisonedForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: PetLogStore.dir)
        PetLogStore.resetPoisonedForTesting()
        PetLogStore.dir = originalDir
        PetLogStore.testIsolationSemaphore.signal()
        super.tearDown()
    }

    private func path(_ file: String) -> String {
        (PetLogStore.dir as NSString).appendingPathComponent(file)
    }

    private func entry(_ text: String) -> NotificationEntry {
        NotificationEntry(id: UUID().uuidString, text: text, source: "log", timestamp: Date())
    }

    /// Old-fail reproduction (data-loss guard): a corrupt existing `log.json`
    /// plus a new append must NOT overwrite the original bytes. On HEAD this
    /// failed — `load` returned `[]`, `save([new])` clobbered the file.
    func testCorruptFileIsNotOverwrittenByAppend() throws {
        let corrupt = Data("{ this is not valid json".utf8)
        try corrupt.write(to: URL(fileURLWithPath: path("log.json")))
        let original = try Data(contentsOf: URL(fileURLWithPath: path("log.json")))

        let outcome = PetLogStore.loadOutcome(file: "log.json")
        guard case let .corrupt(entries, recovered) = outcome else {
            return XCTFail("expected corrupt, got \(outcome)")
        }
        XCTAssertTrue(entries.isEmpty, "unrecoverable corrupt load must be empty")
        XCTAssertFalse(recovered, "no backup means no recovery")

        // A fresh append attempt must be refused (fail-closed) rather than
        // overwriting the unreadable original.
        let saved = PetLogStore.save([entry("new reply")], file: "log.json")
        XCTAssertFalse(saved, "save must fail-closed while the file is poisoned")

        let after = try Data(contentsOf: URL(fileURLWithPath: path("log.json")))
        XCTAssertEqual(after, original, "original corrupt bytes must be preserved, never overwritten")

        // A quarantine copy of the corrupt bytes must exist alongside it.
        let quarantines = try FileManager.default
            .contentsOfDirectory(atPath: PetLogStore.dir)
            .filter { $0.hasPrefix("log.json.corrupt-") }
        XCTAssertEqual(quarantines.count, 1, "exactly one quarantine copy expected")
        let qData = try Data(contentsOf: URL(fileURLWithPath: path(quarantines[0])))
        XCTAssertEqual(qData, original, "quarantine copy must hold the original corrupt bytes")
        let perms = try FileManager.default
            .attributesOfItem(atPath: path(quarantines[0]))[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600, "quarantine copy must be owner-only (0600)")
    }

    func testMissingFileReportsMissing() {
        guard case .missing = PetLogStore.loadOutcome(file: "log.json") else {
            return XCTFail("expected missing for a non-existent file")
        }
        XCTAssertTrue(PetLogStore.load(file: "log.json").isEmpty)
    }

    func testCleanRoundTripReportsSuccess() throws {
        let entries = [entry("a"), entry("b")]
        XCTAssertTrue(PetLogStore.save(entries, file: "log.json"))
        let outcome = PetLogStore.loadOutcome(file: "log.json")
        guard case let .success(loaded, dropped) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(loaded.map(\.text), ["a", "b"])
        XCTAssertEqual(dropped, 0)
    }

    /// A successful save maintains a last-known-good `.bak`; a later corrupt
    /// `log.json` is recovered from it (and writes are NOT held fail-closed).
    func testCorruptRecoversFromBackup() throws {
        let good = [entry("kept-1"), entry("kept-2")]
        XCTAssertTrue(PetLogStore.save(good, file: "log.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("log.json.bak")),
                      "a successful save must maintain a .bak")

        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let outcome = PetLogStore.loadOutcome(file: "log.json")
        guard case let .corrupt(entries, recovered) = outcome else {
            return XCTFail("expected corrupt, got \(outcome)")
        }
        XCTAssertTrue(recovered, "must recover from the last-known-good backup")
        XCTAssertEqual(entries.map(\.text), ["kept-1", "kept-2"])

        // Recovered -> writes are allowed again (not poisoned).
        XCTAssertTrue(PetLogStore.save(good + [entry("kept-3")], file: "log.json"),
                      "after recovery, saves must resume")
    }

    /// Per-entry resilience: one undecodable element must not sink the whole
    /// array, but the dropped count is surfaced and a quarantine copy is kept.
    func testPartialDecodeDropsBadEntryWithoutLosingGoodOnes() throws {
        // First element is a valid NotificationEntry; second is missing the
        // required `id`/`timestamp` shape entirely.
        let json = """
        [{"id":"x1","text":"good","source":"log","timestamp":"2026-08-09T00:00:00Z"},
         {"unexpected":"shape"}]
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let outcome = PetLogStore.loadOutcome(file: "log.json")
        guard case let .success(entries, dropped) = outcome else {
            return XCTFail("expected partial success, got \(outcome)")
        }
        XCTAssertEqual(entries.map(\.text), ["good"])
        XCTAssertEqual(dropped, 1, "the one undecodable entry must be surfaced as dropped")

        // A partial decode still quarantines a copy (the next save rewrites
        // without the dropped entry — preserve the original first).
        let quarantines = try FileManager.default
            .contentsOfDirectory(atPath: PetLogStore.dir)
            .filter { $0.hasPrefix("log.json.corrupt-") }
        XCTAssertEqual(quarantines.count, 1, "partial decode must preserve a quarantine copy")

        // ...but writes are NOT held fail-closed (recovery succeeded).
        XCTAssertTrue(PetLogStore.save(entries, file: "log.json"))
    }
}
