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

        XCTAssertEqual(cfg.debugLogging, false)
        XCTAssertEqual(cfg.includeMessageBodyInLogs, false)
        XCTAssertEqual(cfg.lineDefaultConversation, "")
        XCTAssertEqual(cfg.linePollIntervalSeconds, 2)
        XCTAssertEqual(cfg.tmuxEnabled, false)
        XCTAssertEqual(cfg.tmuxSessionModes, [:])
    }

    func testSaveLoadRoundTrip() {
        let store = ConfigStore(defaults: freshDefaults("cfg-roundtrip"))

        var cfg = AppConfig.default
        cfg.debugLogging = true
        cfg.includeMessageBodyInLogs = true
        cfg.lineDefaultConversation = "Yuzuru Honda"
        cfg.linePollIntervalSeconds = 5
        cfg.tmuxEnabled = true
        cfg.tmuxStatusBarUrl = "ws://custom:9999/sessions"
        cfg.tmuxSessionModes = ["project-a": "autonomous", "project-b": "observe"]

        store.save(cfg)
        let loaded = store.load()

        XCTAssertEqual(loaded.debugLogging, true)
        XCTAssertEqual(loaded.includeMessageBodyInLogs, true)
        XCTAssertEqual(loaded.lineDefaultConversation, "Yuzuru Honda")
        XCTAssertEqual(loaded.linePollIntervalSeconds, 5)
        XCTAssertEqual(loaded.tmuxEnabled, true)
        XCTAssertEqual(loaded.tmuxStatusBarUrl, "ws://custom:9999/sessions")
        XCTAssertEqual(loaded.tmuxSessionModes["project-a"], "autonomous")
        XCTAssertEqual(loaded.tmuxSessionModes["project-b"], "observe")
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

        XCTAssertEqual(cfg.tmuxSessionModes["project-x"], "autonomous")
        XCTAssertEqual(cfg.tmuxSessionModes["project-y"], "autonomous")
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
            "clawgate": "autonomous",
            "other-project": "auto",
            "read-only": "observe",
        ]

        store.save(cfg)
        let loaded = store.load()

        XCTAssertEqual(loaded.tmuxSessionModes.count, 3)
        XCTAssertEqual(loaded.tmuxSessionModes["clawgate"], "autonomous")
        XCTAssertEqual(loaded.tmuxSessionModes["other-project"], "auto")
        XCTAssertEqual(loaded.tmuxSessionModes["read-only"], "observe")
    }
}
