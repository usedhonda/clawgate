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
        guard case let .corrupt(entries, recovered, quarantine) = outcome else {
            return XCTFail("expected corrupt, got \(outcome)")
        }
        XCTAssertTrue(entries.isEmpty, "unrecoverable corrupt load must be empty")
        XCTAssertFalse(recovered, "no backup means no recovery")
        XCTAssertNotNil(quarantine, "the corrupt load must report its quarantine copy")

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
        guard case let .success(loaded, dropped, quarantine) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(loaded.map(\.text), ["a", "b"])
        XCTAssertEqual(dropped, 0)
        XCTAssertNil(quarantine, "a clean load quarantines nothing")
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
        guard case let .corrupt(entries, recovered, _) = outcome else {
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
        guard case let .success(entries, dropped, quarantine) = outcome else {
            return XCTFail("expected partial success, got \(outcome)")
        }
        XCTAssertEqual(entries.map(\.text), ["good"])
        XCTAssertEqual(dropped, 1, "the one undecodable entry must be surfaced as dropped")
        XCTAssertNotNil(quarantine, "a partial drop must report its quarantine copy")

        // A partial decode still quarantines a copy (the next save rewrites
        // without the dropped entry — preserve the original first).
        let quarantines = try FileManager.default
            .contentsOfDirectory(atPath: PetLogStore.dir)
            .filter { $0.hasPrefix("log.json.corrupt-") }
        XCTAssertEqual(quarantines.count, 1, "partial decode must preserve a quarantine copy")

        // ...but writes are NOT held fail-closed (recovery succeeded).
        XCTAssertTrue(PetLogStore.save(entries, file: "log.json"))
    }

    // MARK: - D9 follow-up: preservation-before-continue hardening

    /// Guard (a): if the quarantine copy cannot be created, the store must fail
    /// closed rather than let a later save overwrite the un-preserved original.
    func testQuarantineCreationFailurePoisonsAndPreservesOriginal() throws {
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let original = try Data(contentsOf: URL(fileURLWithPath: path("log.json")))

        // Make the store dir read+traverse only so reading the original works
        // but creating the quarantine file fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: PetLogStore.dir)
        let outcome = PetLogStore.loadOutcome(file: "log.json")
        // Restore perms so the assertions below aren't themselves blocked.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: PetLogStore.dir)

        guard case let .corrupt(entries, recovered, quarantine) = outcome else {
            return XCTFail("expected corrupt, got \(outcome)")
        }
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(recovered)
        XCTAssertNil(quarantine, "quarantine failed, so no copy name is reported")
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"), "quarantine failure must poison the file")

        XCTAssertFalse(PetLogStore.save([entry("new")], file: "log.json"),
                       "a poisoned file must refuse writes even though quarantine failed")
        let after = try Data(contentsOf: URL(fileURLWithPath: path("log.json")))
        XCTAssertEqual(after, original, "the un-preserved original must never be overwritten")
        // No quarantine copy was created.
        let quarantines = try FileManager.default.contentsOfDirectory(atPath: PetLogStore.dir)
            .filter { $0.hasPrefix("log.json.corrupt-") }
        XCTAssertTrue(quarantines.isEmpty)
    }

    /// Guard (b): a partially-corrupt backup is not a trustworthy last-known-good
    /// and must be rejected — no salvaging its decodable subset.
    func testPartiallyCorruptBackupIsNotAdoptedForRecovery() throws {
        // `.bak` has one good + one undecodable entry (dropped == 1).
        let bakJSON = """
        [{"id":"g","text":"good","source":"log","timestamp":"2026-08-09T00:00:00Z"},
         {"unexpected":"shape"}]
        """
        try Data(bakJSON.utf8).write(to: URL(fileURLWithPath: path("log.json.bak")))
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))

        let outcome = PetLogStore.loadOutcome(file: "log.json")
        guard case let .corrupt(entries, recovered, _) = outcome else {
            return XCTFail("expected corrupt, got \(outcome)")
        }
        XCTAssertFalse(recovered, "a partially-corrupt backup must not be adopted")
        XCTAssertTrue(entries.isEmpty, "no partial salvage — empty start")
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"), "no usable backup means fail-closed")
    }

    /// F2 (pending-temp): the backup is staged to a pending temp and only
    /// PROMOTED after the primary commits, so a promote failure (here: a
    /// directory blocking the .bak name) leaves the primary DURABLE (new) with a
    /// stale backup — reported as `.committedBackupDegraded`, never a failed
    /// save. (Under the earlier F ordering this same fixture failed BEFORE the
    /// primary; pending-temp moves the failure to promote, after commit.)
    func testBackupPromoteFailureLeavesPrimaryDurableWithDegradedBackup() throws {
        // Seed an existing "old" primary directly (no .bak file).
        try JSONEncoder.iso.encode([entry("old")]).write(to: URL(fileURLWithPath: path("log.json")))
        // Block the .bak name with a directory so the promote rename fails.
        try FileManager.default.createDirectory(atPath: path("log.json.bak"), withIntermediateDirectories: true)

        XCTAssertEqual(PetLogStore.saveOutcome([entry("fresh")], file: "log.json"), .committedBackupDegraded,
                       "primary durable, backup redundancy degraded")

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let primary = try decoder.decode([NotificationEntry].self, from: Data(contentsOf: URL(fileURLWithPath: path("log.json"))))
        XCTAssertEqual(primary.map(\.text), ["fresh"], "the primary commit landed")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("log.json.bak"), isDirectory: &isDir) && isDir.boolValue,
                      "the committed .bak name was never overwritten (still the blocking directory)")
        let temps = try FileManager.default.contentsOfDirectory(atPath: PetLogStore.dir)
            .filter { $0.contains(".pending-") || $0.contains(".tmp-") }
        XCTAssertTrue(temps.isEmpty, "no pending/temp files may linger")
    }

    /// Two-copy ordering (F): a primary chmod/rename failure (after the backup
    /// was written) leaves the OLD primary in place, so a reload returns the old
    /// state — the primary rename is the only commit point.
    func testPrimaryFailureLeavesOldPrimaryForReload() throws {
        // Seed old state via a clean save (primary + .bak both "old").
        XCTAssertTrue(PetLogStore.save([entry("old")], file: "log.json"))
        let before = try Data(contentsOf: URL(fileURLWithPath: path("log.json")))

        // Fail only the primary; the backup write (first) succeeds.
        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }
        XCTAssertFalse(PetLogStore.save([entry("new")], file: "log.json"))
        PetLogStore.applyPermissionsHookForTesting = nil

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("log.json"))), before,
                       "primary bytes must be unchanged (old) after a primary-write failure")
        // A reload returns the old primary content.
        guard case let .success(entries, _, _) = PetLogStore.loadOutcome(file: "log.json") else {
            return XCTFail("expected success reading the old primary")
        }
        XCTAssertEqual(entries.map(\.text), ["old"], "reload must return the old primary state")
    }

    /// F2 (pending-temp): a primary-write failure never touches the committed
    /// `.bak` (the new data was only staged to a pending temp), so a later
    /// corrupt-primary recovery adopts the OLD content, never un-committed data.
    /// No orphan temp files remain.
    func testPrimaryFailureLeavesBackupOldSoRecoveryAdoptsOld() throws {
        XCTAssertTrue(PetLogStore.save([entry("old")], file: "log.json"))  // primary+.bak = old

        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }
        XCTAssertFalse(PetLogStore.save([entry("new")], file: "log.json"))
        PetLogStore.applyPermissionsHookForTesting = nil

        // The committed backup was never touched — it stays "old" (the new data
        // only ever reached a pending temp, which was discarded).
        let bak = try Data(contentsOf: URL(fileURLWithPath: path("log.json.bak")))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode([NotificationEntry].self, from: bak).map(\.text), ["old"],
                       "backup stays committed 'old', never the un-committed 'new'")

        // Corrupt the primary; recovery must adopt the untouched OLD backup.
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        guard case let .corrupt(entries, recovered, _) = PetLogStore.loadOutcome(file: "log.json") else {
            return XCTFail("expected corrupt")
        }
        XCTAssertTrue(recovered)
        XCTAssertEqual(entries.map(\.text), ["old"], "recovery must adopt old, never the un-committed new")

        let temps = try FileManager.default.contentsOfDirectory(atPath: PetLogStore.dir)
            .filter { $0.contains(".pending-") || $0.contains(".tmp-") }
        XCTAssertTrue(temps.isEmpty, "no pending/temp files may linger")
    }

    /// F2 equivalence for the post-double-failure world: a planted, orphaned
    /// `.bak.pending-<uuid>` (what a crash between stage and promote could leave)
    /// must be ignored by every load path — loadOutcome, recovery, and the
    /// quarantine scan never read it.
    func testPlantedPendingBackupIsIgnoredByAllLoadPaths() throws {
        XCTAssertTrue(PetLogStore.save([entry("real")], file: "log.json"))
        // Plant an orphan pending file with different content.
        try JSONEncoder.iso.encode([entry("orphan-uncommitted")])
            .write(to: URL(fileURLWithPath: path("log.json.bak.pending-DEADBEEF")))

        // loadOutcome reads only the committed primary.
        guard case let .success(entries, _, _) = PetLogStore.loadOutcome(file: "log.json") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(entries.map(\.text), ["real"], "planted pending must not be read as the primary")

        // Recovery from a corrupt primary uses the committed .bak, not the pending.
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        guard case let .corrupt(recovered, didRecover, _) = PetLogStore.loadOutcome(file: "log.json") else {
            return XCTFail("expected corrupt")
        }
        XCTAssertTrue(didRecover)
        XCTAssertEqual(recovered.map(\.text), ["real"], "recovery must use the committed backup, not the pending")
    }

    /// F2, no-prior-backup branch: a first-ever save that fails at the primary
    /// leaves NO `.bak` (the new data only reached a discarded pending temp) and
    /// the primary absent.
    func testPrimaryFailureLeavesNoBackupWhenNonePriorExisted() throws {
        // No prior log.json / .bak at all.
        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }
        XCTAssertFalse(PetLogStore.save([entry("new")], file: "log.json"))
        PetLogStore.applyPermissionsHookForTesting = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: path("log.json.bak")),
                       "no .bak may be left when the primary commit failed and none existed before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary),
                       "the primary must remain absent")
        let temps = try FileManager.default.contentsOfDirectory(atPath: PetLogStore.dir)
            .filter { $0.contains(".pending-") || $0.contains(".tmp-") }
        XCTAssertTrue(temps.isEmpty, "no pending/temp files may linger")
    }

    /// D9 gap 3: primary, `.bak`, and quarantine are all owner-only (0600).
    func testAllPersistedFilesAreOwnerOnly() throws {
        XCTAssertTrue(PetLogStore.save([entry("a")], file: "log.json"))
        // Corrupt the primary and reload to force a quarantine copy.
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        _ = PetLogStore.loadOutcome(file: "log.json")

        func mode(_ file: String) throws -> Int16? {
            (try FileManager.default.attributesOfItem(atPath: path(file))[.posixPermissions] as? NSNumber)?.int16Value
        }
        let quarantine = try FileManager.default.contentsOfDirectory(atPath: PetLogStore.dir)
            .first { $0.hasPrefix("log.json.corrupt-") }
        XCTAssertEqual(try mode("log.json.bak"), 0o600, ".bak must be 0600")
        XCTAssertNotNil(quarantine)
        XCTAssertEqual(try mode(quarantine!), 0o600, "quarantine must be 0600")

        // A fresh clean save gives a primary at 0600 too.
        PetLogStore.resetPoisonedForTesting()
        try? FileManager.default.removeItem(atPath: path("log.json"))
        try? FileManager.default.removeItem(atPath: path("log.json.bak"))
        XCTAssertTrue(PetLogStore.save([entry("b")], file: "log.json"))
        XCTAssertEqual(try mode("log.json"), 0o600, "primary must be 0600")
    }

    // MARK: - D54 + chmod failure surfacing

    private func dirMode() throws -> Int16? {
        (try FileManager.default.attributesOfItem(atPath: PetLogStore.dir)[.posixPermissions] as? NSNumber)?.int16Value
    }

    private func mode(_ file: String) throws -> Int16? {
        (try FileManager.default.attributesOfItem(atPath: path(file))[.posixPermissions] as? NSNumber)?.int16Value
    }

    /// D54: a freshly created store dir is owner-only (0700).
    func testFreshStoreDirectoryIsOwnerOnly() throws {
        // setUp created the dir; remove it so save() re-creates it fresh.
        try FileManager.default.removeItem(atPath: PetLogStore.dir)
        XCTAssertTrue(PetLogStore.save([entry("a")], file: "log.json"))
        XCTAssertEqual(try dirMode(), 0o700, "a fresh store dir must be 0700")
    }

    /// D54: an existing umask-0755 dir converges to 0700 on save.
    func testExistingLooseDirectoryConvergesToOwnerOnly() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: PetLogStore.dir)
        XCTAssertTrue(PetLogStore.save([entry("a")], file: "log.json"))
        XCTAssertEqual(try dirMode(), 0o700, "an existing 0755 dir must converge to 0700")
    }

    /// A chmod failure at the directory surfaces as a save failure.
    func testDirectoryPermissionFailureIsSaveFailure() {
        PetLogStore.applyPermissionsHookForTesting = { $0 == PetLogStore.dir ? false : true }
        XCTAssertFalse(PetLogStore.save([entry("a")], file: "log.json"),
                       "a dir chmod failure must surface as save failure")
    }

    /// A chmod failure at the primary file surfaces as a save failure.
    func testPrimaryPermissionFailureIsSaveFailure() {
        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }
        XCTAssertFalse(PetLogStore.save([entry("a")], file: "log.json"),
                       "a primary chmod failure must surface as save failure")
    }

    /// A chmod failure at the .bak file surfaces as a save failure.
    func testBackupPermissionFailureIsSaveFailure() {
        let bak = path("log.json.bak")
        PetLogStore.applyPermissionsHookForTesting = { $0 == bak ? false : true }
        XCTAssertFalse(PetLogStore.save([entry("a")], file: "log.json"),
                       "a .bak chmod failure must surface as save failure")
    }

    // MARK: - D54 load-path permission convergence

    /// A load-only startup (no save) still tightens an existing 0755 dir and
    /// existing 0644 primary/.bak to owner-only, without touching content.
    func testLoadOnlyConvergesExistingDirAndFilesToOwnerOnly() throws {
        // Write primary + .bak directly (bypassing save) and loosen their modes
        // to what an older version could have left behind.
        let bytes = try JSONEncoder.iso.encode([entry("kept")])
        try bytes.write(to: URL(fileURLWithPath: path("log.json")))
        try bytes.write(to: URL(fileURLWithPath: path("log.json.bak")))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path("log.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path("log.json.bak"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: PetLogStore.dir)
        let before = try Data(contentsOf: URL(fileURLWithPath: path("log.json")))

        XCTAssertTrue(PetLogStore.convergePermissionsOnLoad(file: "log.json"))

        XCTAssertEqual(try dirMode(), 0o700, "dir must converge to 0700 on load")
        XCTAssertEqual(try mode("log.json"), 0o600, "existing primary must converge to 0600 on load")
        XCTAssertEqual(try mode("log.json.bak"), 0o600, "existing .bak must converge to 0600 on load")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("log.json"))), before,
                       "convergence must never touch file content")
    }

    /// A load-time chmod failure leaves the original bytes untouched and is
    /// reported (false) so the caller can raise a durable security warning.
    func testLoadPermissionFailureIsReportedWithBytesUntouched() throws {
        let bytes = try JSONEncoder.iso.encode([entry("kept")])
        try bytes.write(to: URL(fileURLWithPath: path("log.json")))
        let before = try Data(contentsOf: URL(fileURLWithPath: path("log.json")))

        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }
        XCTAssertFalse(PetLogStore.convergePermissionsOnLoad(file: "log.json"),
                       "a load-time chmod failure must be reported")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("log.json"))), before,
                       "a chmod failure must not touch bytes")
    }

    /// The corrupt/quarantine load path runs in an already-0700 dir.
    func testCorruptLoadPathConvergesDirTo0700() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: PetLogStore.dir)
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))

        XCTAssertTrue(PetLogStore.convergePermissionsOnLoad(file: "log.json"))
        _ = PetLogStore.loadOutcome(file: "log.json")  // writes a quarantine copy

        XCTAssertEqual(try dirMode(), 0o700, "dir must be 0700 across the corrupt/quarantine path")
        let quarantine = try FileManager.default.contentsOfDirectory(atPath: PetLogStore.dir)
            .first { $0.hasPrefix("log.json.corrupt-") }
        XCTAssertNotNil(quarantine)
        XCTAssertEqual(try mode(quarantine!), 0o600, "quarantine copy stays 0600 in the 0700 dir")
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
}
