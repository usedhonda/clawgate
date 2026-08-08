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

        let (warnings, degraded) = PetLogStore.loadRecoveryWarnings()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(degraded, "both copies unreadable must report durability degraded, not a silent empty")

        // The degraded load must also propagate to the model's Published status.
        let restarted = PetModel()
        restarted.restorePersistedLogsForTesting()
        XCTAssertTrue(restarted.recoveryWarningPersistenceDegraded,
                      "a degraded warnings-store load must raise the model's Published flag")
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

    /// A permission failure AND whole-file corruption on the same file also
    /// coexist as distinct issues.
    func testChmodFailurePlusCorruptKeepsBothIssues() throws {
        try Data("{ corrupt".utf8).write(to: URL(fileURLWithPath: path("log.json")))
        let primary = path("log.json")
        PetLogStore.applyPermissionsHookForTesting = { $0 == primary ? false : true }

        let model = PetModel()
        model.restorePersistedLogsForTesting()

        let kinds = Set(model.logRecoveryWarnings.filter { $0.file == "log.json" }.map(\.kind))
        XCTAssertTrue(kinds.contains("insecurePermissions"))
        XCTAssertTrue(kinds.contains("corrupt"))
        XCTAssertEqual(kinds.count, 2, "permission + corrupt issues coexist, neither erased")
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
        let (warnings, degraded) = PetLogStore.loadRecoveryWarnings()

        let mode = (try FileManager.default.attributesOfItem(atPath: warningsPath)[.posixPermissions] as? NSNumber)?.int16Value
        XCTAssertEqual(mode, 0o600, "an existing 0644 warnings file must converge to 0600 on load")
        XCTAssertFalse(degraded)
        XCTAssertTrue(warnings.contains { $0.file == "log.json" && $0.kind == "corrupt" })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: warningsPath)), before,
                       "convergence must not alter content")
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
}
