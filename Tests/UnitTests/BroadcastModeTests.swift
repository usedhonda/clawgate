import XCTest
@testable import ClawGate

/// Covers broadcast (streaming) mode: config persistence plus the PetModel
/// body-suppression gate that hides message bodies while surfacing only a
/// content-free indicator.
final class BroadcastModeTests: XCTestCase {
    private var originalLogStoreDir = ""

    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "clawgate.tests.\(name)")!
        d.removePersistentDomain(forName: "clawgate.tests.\(name)")
        return d
    }

    override func setUp() {
        super.setUp()
        // showNotification -> addNotificationEntry -> PetLogStore.save writes
        // notifications.json; isolate it from the user's real ~/.clawgate/logs.
        PetLogStore.testIsolationSemaphore.wait()
        originalLogStoreDir = PetLogStore.dir
        PetLogStore.dir = NSTemporaryDirectory() + "clawgate-test-logs-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: PetLogStore.dir)
        PetLogStore.dir = originalLogStoreDir
        PetLogStore.testIsolationSemaphore.signal()
        super.tearDown()
    }

    // MARK: - Config round-trip

    func testBroadcastModeConfigRoundTrip() {
        let store = ConfigStore(defaults: freshDefaults("broadcast-roundtrip"))
        XCTAssertFalse(store.load().broadcastMode, "default should be off")

        var cfg = AppConfig.default
        cfg.broadcastMode = true
        store.save(cfg)
        XCTAssertTrue(store.load().broadcastMode)

        cfg.broadcastMode = false
        store.save(cfg)
        XCTAssertFalse(store.load().broadcastMode)
    }

    // MARK: - PetModel suppression gate

    @MainActor
    func testBroadcastOnSuppressesBodyButKeepsHistoryAndShowsIndicator() {
        let model = PetModel()
        model.broadcastMode = true

        let msg = OpenClawChatMessage(role: .assistant, text: "secret body text")
        model.showNotification(msg)

        XCTAssertNil(model.notificationMessage,
                     "broadcast on must not surface the message body")
        XCTAssertEqual(model.notificationHistory.count, 1,
                       "history must still be written")
        XCTAssertEqual(model.notificationHistory.first?.text, "secret body text")
        XCTAssertEqual(model.whisperText, "💬 メッセージ受信",
                       "only the content-free indicator is shown")
    }

    @MainActor
    func testBroadcastOffSetsNotificationMessageAsBefore() {
        let model = PetModel()
        model.broadcastMode = false

        let msg = OpenClawChatMessage(role: .assistant, text: "visible body text")
        model.showNotification(msg)

        XCTAssertNotNil(model.notificationMessage,
                        "broadcast off keeps the legacy body notification")
        XCTAssertEqual(model.notificationMessage?.text, "visible body text")
        XCTAssertEqual(model.notificationHistory.count, 1)
    }

    @MainActor
    func testBroadcastOnSuppressesPlainWhisperButAllowsIndicator() {
        let model = PetModel()
        model.broadcastMode = true

        model.showWhisper("Connected")
        XCTAssertNil(model.whisperText, "plain reaction whispers are suppressed")

        model.showWhisper("💬 indicator", allowInBroadcast: true)
        XCTAssertEqual(model.whisperText, "💬 indicator",
                       "explicitly allowed indicator still shows")
    }
}
