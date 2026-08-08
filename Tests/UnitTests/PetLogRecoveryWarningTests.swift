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

    private func entry(_ text: String) -> NotificationEntry {
        NotificationEntry(id: UUID().uuidString, text: text, source: "log", timestamp: Date())
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

    /// Whole-file (unrecoverable) corruption surfaces as a writeBlocked warning
    /// carrying the incident's quarantine reference (H).
    func testCorruptFileSurfacesDurableWarning() throws {
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: path("summon.json")))

        let model = PetModel()
        model.restorePersistedLogsForTesting()

        guard let warning = model.logRecoveryWarnings.first(where: { $0.file == "summon.json" && $0.kind == "writeBlocked" }) else {
            return XCTFail("a poisoned corrupt file must raise a writeBlocked warning")
        }
        XCTAssertNotNil(warning.quarantine, "the writeBlocked warning must reference the quarantine copy")
        XCTAssertTrue(PetLogStore.isPoisoned("summon.json"))
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

    // MARK: - Warning persistence as a commit (D39 completion blocker)

    private func partialDropFixture() throws {
        let json = """
        [{"id":"g1","text":"good","source":"log","timestamp":"2026-08-09T00:00:00Z"},
         {"unexpected":"shape"}]
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: path("log.json")))
    }

    /// If the warning set can't be persisted at restore, the warning stays
    /// visible in memory AND the durability-degraded flag is raised — the loss
    /// is fail-visible, never silently assumed persisted.
    func testWarningPersistFailureIsFailVisible() throws {
        try partialDropFixture()
        // Fail the chmod of the warnings file so saveRecoveryWarnings returns false.
        let warningsPath = path("recovery-warnings.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == warningsPath ? false : true }

        let model = PetModel()
        model.restorePersistedLogsForTesting()

        XCTAssertTrue(model.logRecoveryWarnings.contains { $0.file == "log.json" },
                      "the warning must remain visible in memory")
        XCTAssertTrue(model.recoveryWarningPersistenceDegraded,
                      "a failed warning persist must raise the durability-degraded flag")
    }

    /// Acknowledge is a commit: if the empty set can't be persisted, the
    /// warnings are NOT cleared and durability-degraded is raised.
    func testAcknowledgeFailureKeepsWarningsVisible() throws {
        try partialDropFixture()
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertFalse(model.logRecoveryWarnings.isEmpty)

        let warningsPath = path("recovery-warnings.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == warningsPath ? false : true }
        model.acknowledgeLogRecoveryWarnings()

        XCTAssertFalse(model.logRecoveryWarnings.isEmpty,
                       "a failed acknowledge must not clear the warnings ahead of disk")
        XCTAssertTrue(model.recoveryWarningPersistenceDegraded)

        // A successful acknowledge clears it durably.
        PetLogStore.applyPermissionsHookForTesting = nil
        model.acknowledgeLogRecoveryWarnings()
        XCTAssertTrue(model.logRecoveryWarnings.isEmpty)
        XCTAssertFalse(model.recoveryWarningPersistenceDegraded)
    }

    /// The warnings store has last-known-good backup resilience: after the
    /// source log is cleaned by an append (so the drop can NO LONGER be
    /// re-derived), a corrupt warnings primary must still recover the warning
    /// from its .bak across a restart.
    func testWarningsStoreRecoversFromBackupOnCorruptPrimary() throws {
        try partialDropFixture()
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertTrue(model.logRecoveryWarnings.contains { $0.file == "log.json" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("recovery-warnings.json.bak")),
                      "the warnings store must maintain a .bak")

        // Append cleans log.json (rewrites without the bad entry) — a restart
        // load of log.json is now dropped==0, so the warning can ONLY come from
        // the warnings backup, not from re-detection.
        model.addSummonResult(text: "clean arrival", source: "log", parseAsStructured: false)

        // Corrupt the warnings primary; a restart must recover from the backup.
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("recovery-warnings.json")))
        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()

        let logWarnings = restarted.logRecoveryWarnings.filter { $0.file == "log.json" }
        XCTAssertEqual(logWarnings.count, 1, "exactly the backed-up warning, not a re-derived one")
        XCTAssertEqual(logWarnings.first?.droppedCount, 1,
                       "the recovered warning must carry the original drop count")
        XCTAssertFalse(restarted.logReplies.contains { $0.text.contains("shape") },
                       "log.json was cleaned by the append — the drop is no longer re-derivable")
    }

    /// Both copies of the warnings store corrupt -> visible durability failure,
    /// not a silent empty.
    func testWarningsStoreBothCopiesCorruptIsVisibleFailure() throws {
        // Seed a valid warnings store, then corrupt both copies.
        try partialDropFixture()
        let seed = PetModel()
        seed.restorePersistedLogsForTesting()
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("recovery-warnings.json")))
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("recovery-warnings.json.bak")))

        let (warnings, degraded, _) = PetLogStore.loadRecoveryWarnings()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(degraded, "both copies unreadable must report durability degraded, not a silent empty")

        // The model surfaces the loss as a durable warningStoreCorrupt entry.
        // (The Published degraded FLAG reflects CURRENT persistence health, which
        // becomes healthy again once the store is rewritten — K — so the
        // evidence lives in the warning entry, not the transient flag.)
        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()
        XCTAssertTrue(restarted.logRecoveryWarnings.contains {
            $0.file == PetLogStore.recoveryWarningsFile && $0.kind == "warningStoreCorrupt" },
            "a degraded warnings-store load must surface a durable warningStoreCorrupt entry")
    }

    /// F2: a promote failure on a main-store append surfaces a durable
    /// backupDegraded warning (primary durable, redundancy lost) rather than a
    /// swallowed/failed save.
    func testMainStorePromoteFailureSurfacesBackupDegradedWarning() throws {
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        // Block the log.json.bak name so the append's backup promote fails.
        try FileManager.default.createDirectory(atPath: path("log.json.bak"), withIntermediateDirectories: true)

        // A log append (real persist path) — primary commits, promote fails.
        model.addSummonResult(text: "landed", source: "log", parseAsStructured: false)
        XCTAssertTrue(model.logReplies.contains { $0.text == "landed" }, "the primary append must land")
        XCTAssertTrue(model.logRecoveryWarnings.contains {
            $0.file == "log.json" && $0.kind == "backupDegraded" },
            "a promote failure must surface a durable backupDegraded warning")
    }

    // MARK: - Concurrent issues on one file (D39/D54 interaction)

    /// A permission failure AND a partial drop on the SAME file are independent
    /// issues that must both stay visible — neither erases the other (warning
    /// identity is (file, kind), not file alone).
    func testChmodFailurePlusPartialDropKeepsBothIssues() throws {
        try partialDropFixture()
        // Fail the chmod of log.json so convergePermissionsOnLoad raises an
        // insecurePermissions issue, while the load still detects the drop.
        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }

        let model = PetModel()
        model.restorePersistedLogsForTesting()

        let kinds = Set(model.logRecoveryWarnings.filter { $0.file == "log.json" }.map(\.kind))
        XCTAssertTrue(kinds.contains("insecurePermissions"), "permission issue must survive")
        XCTAssertTrue(kinds.contains("partialDrop"), "partial-drop issue must survive alongside it")
        XCTAssertEqual(kinds.count, 2, "both issues are distinct and coexist")
    }

    /// A permission failure AND an unrecoverable corruption (writeBlocked) on the
    /// same file coexist as distinct issues.
    func testChmodFailurePlusCorruptKeepsBothIssues() throws {
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }

        let model = PetModel()
        model.restorePersistedLogsForTesting()

        let kinds = Set(model.logRecoveryWarnings.filter { $0.file == "log.json" }.map(\.kind))
        XCTAssertTrue(kinds.contains("insecurePermissions"))
        XCTAssertTrue(kinds.contains("writeBlocked"))
        XCTAssertEqual(kinds.count, 2, "permission + writeBlocked issues coexist, neither erased")
    }

    /// A single issue can be acknowledged independently without dropping a still-
    /// open issue on the same file.
    func testSingleIssueAcknowledgeLeavesOthers() throws {
        try partialDropFixture()
        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        PetLogStore.applyPermissionsHookForTesting = nil  // let ack persist succeed

        model.acknowledgeLogRecoveryWarning(file: "log.json", kind: "insecurePermissions")

        let kinds = Set(model.logRecoveryWarnings.filter { $0.file == "log.json" }.map(\.kind))
        XCTAssertFalse(kinds.contains("insecurePermissions"), "the acknowledged issue is cleared")
        XCTAssertTrue(kinds.contains("partialDrop"), "the other issue on the same file remains")
    }

    // MARK: - Both-copies-corrupt survives restart (E)

    /// When both copies of the warnings store are corrupt, the loss must be
    /// committed as a durable synthetic warning that survives a RESTART (not
    /// just this session) until the user acknowledges it — a clean empty on the
    /// next launch must not erase the evidence.
    func testBothCopiesCorruptWarningSurvivesRestartUntilAck() throws {
        // Seed a valid warnings store, then clean the source log so the only
        // way a warning can reappear post-restart is the persisted store.
        try partialDropFixture()
        let seed = PetModel()
        seed.restorePersistedLogsForTesting()
        seed.addSummonResult(text: "clean", source: "log", parseAsStructured: false)  // clears log.json drop

        // Corrupt BOTH copies of the warnings store.
        try Data("{ x".utf8).write(to: URL(fileURLWithPath: path("recovery-warnings.json")))
        try Data("{ x".utf8).write(to: URL(fileURLWithPath: path("recovery-warnings.json.bak")))

        // Restore detects the double corruption and commits a synthetic marker.
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertTrue(model.logRecoveryWarnings.contains {
            $0.file == PetLogStore.recoveryWarningsFile && $0.kind == "warningStoreCorrupt" })

        // RESTART: a fresh model reading the rewritten (now valid) store must
        // still see the synthetic warning — the evidence survived the restart.
        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()
        XCTAssertTrue(restarted.logRecoveryWarnings.contains {
            $0.file == PetLogStore.recoveryWarningsFile && $0.kind == "warningStoreCorrupt" },
            "the durable warning must survive a restart, not vanish on the next clean read")

        // Only an explicit acknowledge clears it, durably across another restart.
        restarted.acknowledgeLogRecoveryWarnings()
        let afterAck = PetModel()
        afterAck.restorePersistedLogsForTesting()
        XCTAssertFalse(afterAck.logRecoveryWarnings.contains {
            $0.kind == "warningStoreCorrupt" }, "acknowledged marker must not return")
    }

    /// rename atomicity: an acknowledge whose chmod fails must NOT leave disk at
    /// [] — the temp file is discarded, the previous persisted warnings survive,
    /// and a restart still shows them.
    func testAcknowledgeChmodFailureLeavesPriorWarningsOnDisk() throws {
        try partialDropFixture()
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertTrue(model.logRecoveryWarnings.contains { $0.file == "log.json" })

        // Fail the chmod during ack's warnings write — atomic write must roll
        // back (never rename the empty temp onto the live warnings file).
        let warningsPath = path("recovery-warnings.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == warningsPath ? false : true }
        model.acknowledgeLogRecoveryWarnings()
        PetLogStore.applyPermissionsHookForTesting = nil

        // A restart still sees the original warning — disk was never cleared.
        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()
        XCTAssertTrue(restarted.logRecoveryWarnings.contains { $0.file == "log.json" },
                      "a failed ack must not have written an empty set to disk")
    }

    /// Two-copy ordering (F): an ack whose BACKUP write fails leaves the primary
    /// warnings file untouched (backup is written first, primary is the commit
    /// point) — so a restart still shows the warning.
    func testAcknowledgeBackupFailureLeavesWarningOnDiskAcrossRestart() throws {
        try partialDropFixture()
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertTrue(model.logRecoveryWarnings.contains { $0.file == "log.json" })

        // Fail the .bak write during ack; with backup-first ordering the primary
        // (still holding the warning) is never reached/overwritten.
        let warningsBak = path("recovery-warnings.json.bak")
        PetLogStore.applyPermissionsHookForTesting = { $0 == warningsBak ? false : true }
        model.acknowledgeLogRecoveryWarnings()
        PetLogStore.applyPermissionsHookForTesting = nil

        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()
        XCTAssertTrue(restarted.logRecoveryWarnings.contains { $0.file == "log.json" },
                      "an ack backup failure must leave the primary warning intact across a restart")
    }

    /// F2: an ack whose PRIMARY write fails rolls the warnings backup back to the
    /// prior warnings — so even if the primary is later corrupted, recovery
    /// adopts the old warnings (not the un-committed []). The un-acknowledged
    /// warning survives a restart.
    func testAckPrimaryFailureThenCorruptPrimaryStillRecoversWarning() throws {
        try partialDropFixture()
        let model = PetModel()
        model.restorePersistedLogsForTesting()  // writes recovery-warnings.json{,.bak} = [warning]
        XCTAssertTrue(model.logRecoveryWarnings.contains { $0.file == "log.json" })

        // Ack with the warnings PRIMARY write failing (backup written [] then
        // rolled back to the prior [warning]).
        let warningsPrimary = path("recovery-warnings.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == warningsPrimary ? false : true }
        model.acknowledgeLogRecoveryWarnings()
        PetLogStore.applyPermissionsHookForTesting = nil

        // Now corrupt the warnings PRIMARY: recovery must fall back to the
        // rolled-back backup that still holds the warning, not an empty set.
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("recovery-warnings.json")))
        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()
        XCTAssertTrue(restarted.logRecoveryWarnings.contains { $0.file == "log.json" },
                      "recovery must adopt the rolled-back warnings backup, not the un-committed empty")
    }

    /// The warnings store's own perms are converged on load: a pre-existing
    /// 0644 recovery-warnings.json (older version) is tightened to 0600 at
    /// restore, without touching content.
    func testWarningsStoreFileConvergesToOwnerOnlyOnLoad() throws {
        // Hand-write a valid warnings file at a loose 0644.
        let warning = PetLogRecoveryWarning(file: "log.json", kind: "corrupt",
                                            droppedCount: 0, quarantine: nil, detectedAt: Date())
        let data = try JSONEncoder.iso.encode([warning])
        let warningsPath = path("recovery-warnings.json")
        try data.write(to: URL(fileURLWithPath: warningsPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: warningsPath)
        let before = try Data(contentsOf: URL(fileURLWithPath: warningsPath))

        // loadRecoveryWarnings converges perms before reading (and does NOT
        // re-save), so this isolates the on-load convergence from the later
        // save() in a full restore.
        let (warnings, degraded, _) = PetLogStore.loadRecoveryWarnings()

        let mode = (try FileManager.default.attributesOfItem(atPath: warningsPath)[.posixPermissions] as? NSNumber)?.int16Value
        XCTAssertEqual(mode, 0o600, "an existing 0644 warnings file must converge to 0600 on load")
        XCTAssertFalse(degraded)
        XCTAssertTrue(warnings.contains { $0.file == "log.json" && $0.kind == "corrupt" })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: warningsPath)), before,
                       "convergence must not alter content")
    }

    // MARK: - Acknowledge vs resolve (D99)

    /// Acknowledging a poisoned (write-blocked) store must NOT clear its warning
    /// or unblock writes — only resolve does. Otherwise ack creates a silent
    /// write-disabled state.
    func testAcknowledgeDoesNotClearOrUnblockPoisonedStore() throws {
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"))
        XCTAssertTrue(model.logRecoveryWarnings.contains { $0.file == "log.json" })

        model.acknowledgeLogRecoveryWarnings()

        XCTAssertTrue(model.logRecoveryWarnings.contains { $0.file == "log.json" },
                      "a poisoned store's warning must remain after ack (blocked status persists)")
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"), "ack must not unblock the store")
        XCTAssertFalse(PetLogStore.save([entry("x")], file: "log.json"), "writes still refused after ack")
    }

    /// Resolve recovers a poisoned store: quarantine bytes are preserved, the
    /// poison clears, writes resume, and a restart reads a clean store.
    func testResolveRecoversPoisonedStoreAndPreservesQuarantine() throws {
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"))
        let quarantineName = try FileManager.default.contentsOfDirectory(atPath: PetLogStore.dir)
            .first { $0.hasPrefix("log.json.corrupt-") }
        let quarantineBytes = try Data(contentsOf: URL(fileURLWithPath: path(quarantineName!)))

        XCTAssertTrue(model.resolveLogStoreCorruption(file: "log.json"), "resolve must succeed with a quarantine present")

        XCTAssertFalse(PetLogStore.isPoisoned("log.json"), "resolve clears the poison")
        XCTAssertFalse(model.logRecoveryWarnings.contains { $0.file == "log.json" }, "resolve clears the warning")
        XCTAssertTrue(PetLogStore.save([entry("fresh")], file: "log.json"), "writes resume after resolve")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path(quarantineName!))), quarantineBytes,
                       "the quarantine evidence must be untouched by resolve")

        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()
        XCTAssertFalse(restarted.logRecoveryWarnings.contains { $0.file == "log.json" }, "restart reads a clean store")
    }

    /// Resolve is refused when no quarantine copy exists (evidence not
    /// preserved) — the corrupt bytes must not be overwritten blind.
    func testResolveRefusedWhenQuarantineMissing() throws {
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: PetLogStore.dir)
        _ = PetLogStore.loadOutcome(file: "log.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: PetLogStore.dir)
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"))

        let model = PetModel()
        XCTAssertFalse(model.resolveLogStoreCorruption(file: "log.json"),
                       "resolve must refuse when no quarantine copy preserved the original")
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"), "store stays fail-closed")
    }

    /// H cross-case: a poisoned file carrying BOTH writeBlocked and an
    /// informational kind — the informational kind is individually ackable while
    /// writeBlocked is refused and stays visible. (Unrecoverable corruption plus
    /// a chmod failure gives exactly this pair: writeBlocked + insecurePermissions.)
    func testWriteBlockedRefusedButCoexistingKindAckable() throws {
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        PetLogStore.applyPermissionsHookForTesting = nil
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"))

        let kinds0 = Set(model.logRecoveryWarnings.filter { $0.file == "log.json" }.map(\.kind))
        XCTAssertTrue(kinds0.contains("writeBlocked"))
        XCTAssertTrue(kinds0.contains("insecurePermissions"), "both issues present on the poisoned file")

        // The informational kind is individually acknowledgeable...
        XCTAssertTrue(model.acknowledgeLogRecoveryWarning(file: "log.json", kind: "insecurePermissions"),
                      "a non-block kind must be individually ackable even on a poisoned file")
        // ...but writeBlocked is refused and stays visible.
        XCTAssertFalse(model.acknowledgeLogRecoveryWarning(file: "log.json", kind: "writeBlocked"),
                       "the active write-block must not be ackable")
        let kinds1 = Set(model.logRecoveryWarnings.filter { $0.file == "log.json" }.map(\.kind))
        XCTAssertFalse(kinds1.contains("insecurePermissions"), "acked informational kind is gone")
        XCTAssertTrue(kinds1.contains("writeBlocked"), "write-block stays visible")
    }

    /// H: resolve clears ONLY the writeBlocked warning for a file; an unrelated
    /// informational kind on the same file remains for separate acknowledgement.
    func testResolveClearsOnlyWriteBlockedLeavingOtherKinds() throws {
        // Corrupt log.json (poisoned → writeBlocked), and also fail its chmod so
        // an independent insecurePermissions warning coexists.
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        PetLogStore.applyPermissionsHookForTesting = nil
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"))

        XCTAssertTrue(model.resolveLogStoreCorruption(file: "log.json"))
        let kinds = Set(model.logRecoveryWarnings.filter { $0.file == "log.json" }.map(\.kind))
        XCTAssertFalse(kinds.contains("writeBlocked"), "resolve clears the write-block")
        XCTAssertTrue(kinds.contains("insecurePermissions"), "an unrelated kind on the same file remains")
    }

    /// L: resolve is transactional — if the writeBlocked clear can't be
    /// persisted (warnings-store save fails), resolve returns false and flags
    /// degraded, even though the store itself recovered; the stale writeBlocked
    /// then durably reconciles on the next (healthy) restart. No dead-end.
    func testResolveWarningCommitFailureReconcilesOnRestart() throws {
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"))

        // Fail the warnings-store persist during the resolve's warning clear.
        let warningsPath = path("recovery-warnings.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == warningsPath ? false : true }
        XCTAssertFalse(model.resolveLogStoreCorruption(file: "log.json"),
                       "a failed warning-clear commit must make resolve return false")
        PetLogStore.applyPermissionsHookForTesting = nil

        // ...but the store itself recovered (fresh log.json committed).
        XCTAssertFalse(PetLogStore.isPoisoned("log.json"), "the store recovered despite the warning-clear failure")
        XCTAssertTrue(model.recoveryWarningPersistenceDegraded, "and degraded is flagged")

        // Next restart: log.json is healthy, so the stale writeBlocked derive-clears.
        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()
        XCTAssertFalse(restarted.logRecoveryWarnings.contains {
            $0.file == "log.json" && $0.kind == "writeBlocked" },
            "the stale writeBlocked must durably reconcile on a healthy restart — no dead-end")
    }

    /// L: a stale writeBlocked on a file fixed out-of-band (healthy on next
    /// launch) is derive-cleared under commit discipline.
    func testStaleWriteBlockedClearsWhenFileHealthyOnRestart() throws {
        // Persist a warnings store holding a writeBlocked for a file that is NOT
        // corrupt on disk (simulating an out-of-band repair).
        try Data("[]".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let stale = PetLogRecoveryWarning(file: "log.json", kind: "writeBlocked",
                                          droppedCount: 0, quarantine: nil, detectedAt: Date())
        let data = try JSONEncoder.iso.encode([stale])
        try data.write(to: URL(fileURLWithPath: path("recovery-warnings.json")))
        try data.write(to: URL(fileURLWithPath: path("recovery-warnings.json.bak")))

        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertFalse(PetLogStore.isPoisoned("log.json"))
        XCTAssertFalse(model.logRecoveryWarnings.contains {
            $0.file == "log.json" && $0.kind == "writeBlocked" },
            "a stale writeBlocked on a healthy file must be reconciled away")
    }

    /// L point 4: a fresh-store backup promote failure during resolve surfaces a
    /// typed backupDegraded warning (not collapsed into the Bool).
    func testResolveFreshStoreBackupDegradedSurfaces() throws {
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertTrue(PetLogStore.isPoisoned("log.json"))

        // Block log.json.bak so the resolve's fresh save promotes-fails.
        try FileManager.default.createDirectory(atPath: path("log.json.bak"), withIntermediateDirectories: true)
        XCTAssertTrue(model.resolveLogStoreCorruption(file: "log.json"),
                      "resolve still succeeds (primary durable) on a backup-degraded fresh save")
        XCTAssertFalse(PetLogStore.isPoisoned("log.json"))
        XCTAssertTrue(model.logRecoveryWarnings.contains {
            $0.file == "log.json" && $0.kind == "backupDegraded" },
            "a fresh-store promote failure must surface a typed backupDegraded warning")
        XCTAssertFalse(model.logRecoveryWarnings.contains {
            $0.file == "log.json" && $0.kind == "writeBlocked" },
            "the writeBlocked is cleared by the successful resolve")
    }

    /// H: resolve of a healthy (never-poisoned) store is refused — a stray old
    /// quarantine must not authorize wiping a live store.
    func testResolveRefusedOnHealthyStore() throws {
        XCTAssertTrue(PetLogStore.save([entry("live")], file: "log.json"))
        // Plant stale quarantine debris from some prior incident.
        try Data("{ old".utf8).write(to: URL(fileURLWithPath: path("log.json.corrupt-2020-01-01T00-00-00Z-STALE")))
        XCTAssertFalse(PetLogStore.isPoisoned("log.json"))

        let model = PetModel()
        XCTAssertFalse(model.resolveLogStoreCorruption(file: "log.json"),
                       "resolve must refuse a store that isn't currently poisoned")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let primary = try decoder.decode([NotificationEntry].self, from: Data(contentsOf: URL(fileURLWithPath: path("log.json"))))
        XCTAssertEqual(primary.map(\.text), ["live"], "the live store must be untouched")
    }

    // MARK: - Warnings-store permission failure surfaced (D100)

    /// A chmod failure on the warnings store itself is no longer discarded: it
    /// surfaces a typed insecurePermissions status this launch (bytes unchanged)
    /// and re-derives on every subsequent launch until repaired.
    func testWarningsStorePermissionFailureSurfacesAndReDerives() throws {
        // Seed a valid warnings store (partial-drop → restore writes it).
        try partialDropFixture()
        PetModel().restorePersistedLogsForTesting()
        let warningsPath = path("recovery-warnings.json")
        let before = try Data(contentsOf: URL(fileURLWithPath: warningsPath))

        // Fail the chmod of the warnings file on subsequent loads.
        PetLogStore.applyPermissionsHookForTesting = { $0 == warningsPath ? false : true }

        // Current launch: the insecure-perms status is visible for the store.
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        XCTAssertTrue(model.logRecoveryWarnings.contains {
            $0.file == PetLogStore.recoveryWarningsFile && $0.kind == "insecurePermissions" },
            "a warnings-store chmod failure must surface a typed status this launch")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: warningsPath)), before,
                       "the failed convergence must not alter warnings-store bytes")

        // Next launch (still failing): the status re-derives, never silently gone.
        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()
        XCTAssertTrue(restarted.logRecoveryWarnings.contains {
            $0.file == PetLogStore.recoveryWarningsFile && $0.kind == "insecurePermissions" },
            "the status must re-derive from the live permission check each launch")

        // Success path: once perms are fine, the status is not raised.
        PetLogStore.applyPermissionsHookForTesting = nil
        let healthy = PetModel()
        healthy.restorePersistedLogsForTesting()
        XCTAssertFalse(healthy.logRecoveryWarnings.contains {
            $0.file == PetLogStore.recoveryWarningsFile && $0.kind == "insecurePermissions" },
            "a healthy warnings store raises no insecure-perms status")
    }

    /// I guard (1): a converge failure that STILL persists (fail the converge
    /// once, let the save succeed) durably clears on the next healthy launch and
    /// stays cleared thereafter.
    func testInsecurePermissionsDurablyClearsAfterRepair() throws {
        try partialDropFixture()
        PetModel().restorePersistedLogsForTesting()  // seed a valid warnings store
        let warningsPath = path("recovery-warnings.json")

        // Fail the FIRST chmod hit on the warnings file (its converge), pass the
        // rest (so the trailing persist succeeds and the status is durable).
        var failedOnce = false
        PetLogStore.applyPermissionsHookForTesting = { p in
            if p == warningsPath && !failedOnce { failedOnce = true; return false }
            return true
        }
        let a = PetModel(); a.restorePersistedLogsForTesting()
        XCTAssertTrue(a.logRecoveryWarnings.contains {
            $0.file == PetLogStore.recoveryWarningsFile && $0.kind == "insecurePermissions" },
            "the insecure-perms status is visible the launch it fails")
        PetLogStore.applyPermissionsHookForTesting = nil

        // Healthy restart: the persisted status is derive-cleared, durably.
        let b = PetModel(); b.restorePersistedLogsForTesting()
        XCTAssertFalse(b.logRecoveryWarnings.contains {
            $0.file == PetLogStore.recoveryWarningsFile && $0.kind == "insecurePermissions" },
            "a healthy launch must durably clear the repaired status")
        let c = PetModel(); c.restorePersistedLogsForTesting()
        XCTAssertFalse(c.logRecoveryWarnings.contains {
            $0.file == PetLogStore.recoveryWarningsFile && $0.kind == "insecurePermissions" },
            "the clear must stay cleared on a later launch")
    }

    /// K: a successful persist via single-issue ack (or resolve) recovers the
    /// degraded flag to false — a full warning-set commit is healthy evidence,
    /// not just the bulk-ack path.
    func testSingleAckSuccessRecoversDegradedFlag() throws {
        // Two independent informational issues so one remains after a single ack.
        try Data("[]".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let m = PetModel()
        m.restorePersistedLogsForTesting()
        m.logRecoveryWarnings = [
            PetLogRecoveryWarning(file: "log.json", kind: "insecurePermissions", droppedCount: 0, quarantine: nil, detectedAt: Date()),
            PetLogRecoveryWarning(file: "summon.json", kind: "partialDrop", droppedCount: 1, quarantine: nil, detectedAt: Date()),
        ]
        m.recoveryWarningPersistenceDegraded = true  // simulate a prior persist failure

        XCTAssertTrue(m.acknowledgeLogRecoveryWarning(file: "log.json", kind: "insecurePermissions"))
        XCTAssertFalse(m.recoveryWarningPersistenceDegraded,
                       "a successful single-issue ack persist must recover the degraded flag")
        XCTAssertTrue(m.logRecoveryWarnings.contains { $0.file == "summon.json" }, "the other issue remains")
    }

    /// I guard (2): the derived CLEAR obeys commit discipline — if the clear's
    /// persist fails, the warning stays visible and degraded is flagged.
    func testInsecurePermissionsClearRequiresSuccessfulCommit() throws {
        // Seed a warnings store that already holds an insecurePermissions status.
        let w = PetLogRecoveryWarning(file: PetLogStore.recoveryWarningsFile,
                                      kind: "insecurePermissions", droppedCount: 0,
                                      quarantine: nil, detectedAt: Date())
        let data = try JSONEncoder.iso.encode([w])
        let warningsPath = path("recovery-warnings.json")
        try data.write(to: URL(fileURLWithPath: warningsPath))
        try data.write(to: URL(fileURLWithPath: warningsPath + ".bak"))

        // Pass the FIRST warnings-path chmod (converge succeeds -> a clear is
        // derived) but fail the SECOND (the clear's persist).
        var seen = false
        PetLogStore.applyPermissionsHookForTesting = { p in
            if p == warningsPath { defer { seen = true }; return !seen }
            return true
        }
        let model = PetModel()
        model.restorePersistedLogsForTesting()
        PetLogStore.applyPermissionsHookForTesting = nil

        XCTAssertTrue(model.logRecoveryWarnings.contains {
            $0.file == PetLogStore.recoveryWarningsFile && $0.kind == "insecurePermissions" },
            "a clear whose persist fails must leave the warning visible")
        XCTAssertTrue(model.recoveryWarningPersistenceDegraded, "and flag degraded")
    }

    /// I guard (3): a chmod failure at the dir, the primary, or the .bak of a
    /// store each leaves bytes untouched and re-derives the status every launch.
    func testPermissionFailureAtEachTargetIsByteInvariantAndReDerives() throws {
        for target in ["", ".bak"] {  // primary and backup of log.json
            try Data("[]".utf8).write(to: URL(fileURLWithPath: path("log.json")))
            try Data("[]".utf8).write(to: URL(fileURLWithPath: path("log.json.bak")))
            let targetPath = path("log.json" + target)
            let before = try Data(contentsOf: URL(fileURLWithPath: targetPath))

            PetLogStore.applyPermissionsHookForTesting = { $0 == targetPath ? false : true }
            let model = PetModel(); model.restorePersistedLogsForTesting()
            XCTAssertTrue(model.logRecoveryWarnings.contains {
                $0.file == "log.json" && $0.kind == "insecurePermissions" },
                "a chmod failure at log.json\(target) must surface the status")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: targetPath)), before,
                           "bytes at log.json\(target) must be untouched")
            let restart = PetModel(); restart.restorePersistedLogsForTesting()
            XCTAssertTrue(restart.logRecoveryWarnings.contains {
                $0.file == "log.json" && $0.kind == "insecurePermissions" },
                "the status must re-derive on restart while the failure persists")
            PetLogStore.applyPermissionsHookForTesting = nil
            try? FileManager.default.removeItem(atPath: path("log.json"))
            try? FileManager.default.removeItem(atPath: path("log.json.bak"))
            try? FileManager.default.removeItem(atPath: path("recovery-warnings.json"))
            try? FileManager.default.removeItem(atPath: path("recovery-warnings.json.bak"))
        }
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
}
