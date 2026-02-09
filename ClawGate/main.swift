import AppKit
import Foundation

final class AppRuntime {
    let configStore = ConfigStore()

    private lazy var logger = AppLogger(configStore: configStore)
    private lazy var recentSendTracker = RecentSendTracker()
    private lazy var lineAdapter = LINEAdapter(logger: logger, recentSendTracker: recentSendTracker)

    // Tmux
    private lazy var ccStatusBarClient: CCStatusBarClient = {
        let config = configStore.load()
        return CCStatusBarClient(logger: logger, urlString: config.tmuxStatusBarUrl)
    }()
    private lazy var tmuxAdapter = TmuxAdapter(
        ccClient: ccStatusBarClient,
        configStore: configStore,
        logger: logger
    )

    private lazy var registry = AdapterRegistry(adapters: [lineAdapter, tmuxAdapter])
    private lazy var eventBus = EventBus()
    private lazy var core = BridgeCore(
        eventBus: eventBus,
        registry: registry,
        logger: logger,
        configStore: configStore
    )
    private lazy var server = BridgeServer(core: core)
    private lazy var inboundWatcher = LINEInboundWatcher(
        eventBus: eventBus,
        logger: logger,
        pollIntervalSeconds: configStore.load().linePollIntervalSeconds,
        recentSendTracker: recentSendTracker
    )
    private lazy var notificationBannerWatcher = NotificationBannerWatcher(
        eventBus: eventBus,
        logger: logger,
        recentSendTracker: recentSendTracker
    )
    private lazy var tmuxInboundWatcher = TmuxInboundWatcher(
        ccClient: ccStatusBarClient,
        eventBus: eventBus,
        logger: logger,
        configStore: configStore
    )

    // Keep a weak reference to the delegate for session menu updates
    weak var menuBarDelegate: MenuBarAppDelegate?

    /// All current CC sessions (for menu refresh).
    func allCCSessions() -> [CCStatusBarClient.CCSession] {
        ccStatusBarClient.allSessions()
    }

    func startServer() {
        do {
            try server.start()
            logger.log(.info, "ClawGate started on 127.0.0.1:8765")
        } catch {
            logger.log(.error, "ClawGate failed: \(error)")
        }

        inboundWatcher.start()
        notificationBannerWatcher.start()

        // Start tmux subsystem if enabled
        let config = configStore.load()
        if config.tmuxEnabled {
            startTmuxSubsystem()
        }
    }

    func stopServer() {
        notificationBannerWatcher.stop()
        inboundWatcher.stop()
        tmuxInboundWatcher.stop()
        ccStatusBarClient.disconnect()
        server.stop()
        logger.log(.info, "ClawGate stopped")
    }

    func startTmuxSubsystem() {
        logger.log(.info, "Tmux subsystem starting")
        ccStatusBarClient.onSessionsChanged = { [weak self] in
            guard let self else { return }
            self.menuBarDelegate?.refreshSessionsMenu(sessions: self.ccStatusBarClient.allSessions())
        }
        ccStatusBarClient.connect()
        tmuxInboundWatcher.start()
    }
}

let app = NSApplication.shared
let runtime = AppRuntime()
let delegate = MenuBarAppDelegate(runtime: runtime)
runtime.menuBarDelegate = delegate
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
