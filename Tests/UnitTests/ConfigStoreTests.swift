import XCTest
@testable import ClawGate

final class ConfigStoreTests: XCTestCase {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "clawgate.tests.\(name)")!
        d.removePersistentDomain(forName: "clawgate.tests.\(name)")
        return d
    }

    func testDefaultValues() {
        let store = ConfigStore(defaults: freshDefaults("cfg-defaults"))
        let cfg = store.load()

        XCTAssertEqual(cfg.nodeRole, .client)
        XCTAssertEqual(cfg.debugLogging, false)
        XCTAssertEqual(cfg.includeMessageBodyInLogs, false)
        XCTAssertEqual(cfg.lineDefaultConversation, "")
        XCTAssertEqual(cfg.linePollIntervalSeconds, 1)
        XCTAssertEqual(cfg.tmuxEnabled, false)
        XCTAssertEqual(cfg.tmuxStatusBarURL, "ws://localhost:8080/ws/sessions")
        XCTAssertEqual(cfg.tmuxSessionModes, [:])
        XCTAssertEqual(cfg.remoteAccessEnabled, false)
        XCTAssertEqual(cfg.remoteAccessToken, "")
        XCTAssertEqual(cfg.federationEnabled, false)
        XCTAssertEqual(cfg.federationURL, "")
        XCTAssertEqual(cfg.federationToken, "")
        XCTAssertEqual(cfg.federationReconnectMaxSeconds, 60)
    }

    func testSaveLoadRoundTripForSupportedSettings() {
        let store = ConfigStore(defaults: freshDefaults("cfg-roundtrip"))

        var cfg = AppConfig.default
        cfg.debugLogging = true
        cfg.includeMessageBodyInLogs = true
        cfg.lineDefaultConversation = "Test User"
        cfg.linePollIntervalSeconds = 5
        cfg.tmuxEnabled = true
        cfg.tmuxSessionModes = ["cc:project-a": "autonomous", "cc:project-b": "observe"]
        cfg.remoteAccessEnabled = true
        cfg.remoteAccessToken = "test-token"

        store.save(cfg)
        let loaded = store.load()

        XCTAssertEqual(loaded.debugLogging, true)
        XCTAssertEqual(loaded.includeMessageBodyInLogs, true)
        XCTAssertEqual(loaded.lineDefaultConversation, "Test User")
        XCTAssertEqual(loaded.linePollIntervalSeconds, 5)
        XCTAssertEqual(loaded.tmuxEnabled, true)
        XCTAssertEqual(loaded.tmuxSessionModes["cc:project-a"], "autonomous")
        XCTAssertEqual(loaded.tmuxSessionModes["cc:project-b"], "observe")
        XCTAssertEqual(loaded.remoteAccessEnabled, true)
        XCTAssertEqual(loaded.remoteAccessToken, "test-token")
    }

    func testSaveClearsLegacyRoleAndFederationKeys() {
        let defaults = freshDefaults("cfg-legacy-save-clear")
        let store = ConfigStore(defaults: defaults)

        defaults.set("server", forKey: "clawgate.nodeRole")
        defaults.set("ws://legacy:8080/ws/sessions", forKey: "clawgate.tmuxStatusBarUrl")
        defaults.set(true, forKey: "clawgate.federationEnabled")
        defaults.set("ws://legacy:8765/federation", forKey: "clawgate.federationURL")
        defaults.set("legacy-fed-token", forKey: "clawgate.federationToken")
        defaults.set(120, forKey: "clawgate.federationReconnectMaxSeconds")

        var cfg = store.load()
        cfg.remoteAccessToken = "new-remote-token"
        store.save(cfg)

        XCTAssertNil(defaults.object(forKey: "clawgate.nodeRole"))
        XCTAssertNil(defaults.object(forKey: "clawgate.tmuxStatusBarUrl"))
        XCTAssertNil(defaults.object(forKey: "clawgate.federationEnabled"))
        XCTAssertNil(defaults.object(forKey: "clawgate.federationURL"))
        XCTAssertNil(defaults.object(forKey: "clawgate.federationToken"))
        XCTAssertNil(defaults.object(forKey: "clawgate.federationReconnectMaxSeconds"))
        XCTAssertEqual(defaults.string(forKey: "clawgate.remoteAccessToken"), "new-remote-token")
    }

    func testMigrationAbsorbsFederationTokenIntoRemoteAccessToken() {
        let defaults = freshDefaults("cfg-fed-token-migrate")
        defaults.set("legacy-fed-token", forKey: "clawgate.federationToken")

        let store = ConfigStore(defaults: defaults)
        let cfg = store.load()

        XCTAssertEqual(cfg.remoteAccessToken, "legacy-fed-token")
    }

    func testPollIntervalMigration() {
        let d = freshDefaults("cfg-poll-migrate")
        // Set legacy key before creating ConfigStore (migration happens in init)
        d.set(3, forKey: "clawgate.pollIntervalSeconds")

        let store = ConfigStore(defaults: d)
        let cfg = store.load()

        XCTAssertEqual(cfg.linePollIntervalSeconds, 3)
        // Legacy key should be removed
        XCTAssertNil(d.object(forKey: "clawgate.pollIntervalSeconds"))
    }

    func testTmuxAllowedSessionsMigration() {
        let d = freshDefaults("cfg-tmux-migrate")
        // Set legacy allowed sessions as JSON array
        let json = try! JSONEncoder().encode(["project-x", "project-y"])
        d.set(String(data: json, encoding: .utf8)!, forKey: "clawgate.tmuxAllowedSessions")

        let store = ConfigStore(defaults: d)
        let cfg = store.load()

        XCTAssertEqual(cfg.tmuxSessionModes["cc:project-x"], "autonomous")
        XCTAssertEqual(cfg.tmuxSessionModes["cc:project-y"], "autonomous")
        // Legacy key should be removed
        XCTAssertNil(d.object(forKey: "clawgate.tmuxAllowedSessions"))
    }

    func testMigrationSkippedWhenNewKeyExists() {
        let d = freshDefaults("cfg-migrate-skip")
        // Set both legacy and new key
        d.set(10, forKey: "clawgate.pollIntervalSeconds")
        d.set(5, forKey: "clawgate.linePollIntervalSeconds")

        let store = ConfigStore(defaults: d)
        let cfg = store.load()

        // New key should win, legacy should remain untouched
        XCTAssertEqual(cfg.linePollIntervalSeconds, 5)
    }

    func testPollIntervalMinimumClamp() {
        let d = freshDefaults("cfg-poll-clamp")
        d.set(0, forKey: "clawgate.linePollIntervalSeconds")

        let store = ConfigStore(defaults: d)
        let cfg = store.load()

        XCTAssertEqual(cfg.linePollIntervalSeconds, 1, "Poll interval should be clamped to minimum 1")
    }

    func testTmuxSessionModesJsonPersistence() {
        let store = ConfigStore(defaults: freshDefaults("cfg-modes-json"))

        var cfg = AppConfig.default
        cfg.tmuxSessionModes = [
            "cc:clawgate": "autonomous",
            "codex:clawgate": "auto",
            "cc:read-only": "observe",
        ]

        store.save(cfg)
        let loaded = store.load()

        XCTAssertEqual(loaded.tmuxSessionModes.count, 3)
        XCTAssertEqual(loaded.tmuxSessionModes["cc:clawgate"], "autonomous")
        XCTAssertEqual(loaded.tmuxSessionModes["codex:clawgate"], "auto")
        XCTAssertEqual(loaded.tmuxSessionModes["cc:read-only"], "observe")
    }

    func testModeKeyHelper() {
        XCTAssertEqual(AppConfig.modeKey(sessionType: "claude_code", project: "proj"), "cc:proj")
        XCTAssertEqual(AppConfig.modeKey(sessionType: "codex", project: "proj"), "codex:proj")
        // Unknown session types default to cc prefix
        XCTAssertEqual(AppConfig.modeKey(sessionType: "unknown", project: "proj"), "cc:proj")
    }

    func testBareKeyMigrationToCompositeKey() {
        let d = freshDefaults("cfg-composite-migrate")
        // Simulate old format: bare project keys without "cc:" prefix
        let oldModes: [String: String] = ["project-a": "autonomous", "project-b": "observe"]
        let json = try! JSONEncoder().encode(oldModes)
        d.set(String(data: json, encoding: .utf8)!, forKey: "clawgate.tmuxSessionModes")

        let store = ConfigStore(defaults: d)
        let cfg = store.load()

        // Old bare keys should be migrated to "cc:" prefix
        XCTAssertNil(cfg.tmuxSessionModes["project-a"])
        XCTAssertNil(cfg.tmuxSessionModes["project-b"])
        XCTAssertEqual(cfg.tmuxSessionModes["cc:project-a"], "autonomous")
        XCTAssertEqual(cfg.tmuxSessionModes["cc:project-b"], "observe")
    }

    func testCompositeKeyMigrationPreservesExisting() {
        let d = freshDefaults("cfg-composite-preserve")
        // Mix of old and new format keys
        let modes: [String: String] = [
            "old-project": "auto",
            "cc:new-project": "autonomous",
            "codex:new-project": "observe",
        ]
        let json = try! JSONEncoder().encode(modes)
        d.set(String(data: json, encoding: .utf8)!, forKey: "clawgate.tmuxSessionModes")

        let store = ConfigStore(defaults: d)
        let cfg = store.load()

        // Old bare key migrated
        XCTAssertEqual(cfg.tmuxSessionModes["cc:old-project"], "auto")
        // Existing composite keys preserved
        XCTAssertEqual(cfg.tmuxSessionModes["cc:new-project"], "autonomous")
        XCTAssertEqual(cfg.tmuxSessionModes["codex:new-project"], "observe")
        // Old bare key removed
        XCTAssertNil(cfg.tmuxSessionModes["old-project"])
    }
}
