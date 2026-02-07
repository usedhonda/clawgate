import AppKit
import Foundation

final class AppRuntime {
    let configStore = ConfigStore()
    let tokenManager = BridgeTokenManager(keychain: KeychainStore())
    let pairingManager = PairingCodeManager()

    private lazy var logger = AppLogger(configStore: configStore)
    private lazy var recentSendTracker = RecentSendTracker()
    private lazy var lineAdapter = LINEAdapter(logger: logger, recentSendTracker: recentSendTracker)
    private lazy var registry = AdapterRegistry(adapters: [lineAdapter])
    private lazy var eventBus = EventBus()
    private lazy var core = BridgeCore(
        eventBus: eventBus,
        tokenManager: tokenManager,
        pairingManager: pairingManager,
        registry: registry,
        logger: logger
    )
    private lazy var server = BridgeServer(core: core)
    private lazy var inboundWatcher = LINEInboundWatcher(
        eventBus: eventBus,
        logger: logger,
        pollIntervalSeconds: configStore.load().pollIntervalSeconds,
        recentSendTracker: recentSendTracker
    )
    private lazy var notificationBannerWatcher = NotificationBannerWatcher(
        eventBus: eventBus,
        logger: logger,
        recentSendTracker: recentSendTracker
    )

    func startServer() {
        do {
            try server.start()
            logger.log(.info, "ClawGate started on 127.0.0.1:8765")
        } catch {
            logger.log(.error, "ClawGate failed: \(error)")
        }

        inboundWatcher.start()
        notificationBannerWatcher.start()
    }

    func stopServer() {
        notificationBannerWatcher.stop()
        inboundWatcher.stop()
        server.stop()
        logger.log(.info, "ClawGate stopped")
    }
}

let app = NSApplication.shared
let runtime = AppRuntime()
let delegate = MenuBarAppDelegate(runtime: runtime)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
