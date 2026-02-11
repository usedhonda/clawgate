import AppKit
import Foundation

final class AppRuntime {
    let configStore = ConfigStore()
    lazy var statsCollector = StatsCollector()
    lazy var opsLogStore = OpsLogStore()

    private lazy var logger = AppLogger(configStore: configStore)
    private lazy var recentSendTracker = RecentSendTracker()
    private lazy var lineAdapter = LINEAdapter(logger: logger, recentSendTracker: recentSendTracker)

    // Tmux
    private lazy var ccStatusBarClient = CCStatusBarClient(logger: logger)
    private lazy var tmuxAdapter = TmuxAdapter(
        ccClient: ccStatusBarClient,
        configStore: configStore,
        logger: logger
    )

    private lazy var registry = AdapterRegistry(adapters: enabledAdapters())
    private lazy var eventBus = EventBus()
    private lazy var core = BridgeCore(
        eventBus: eventBus,
        registry: registry,
        logger: logger,
        opsLogStore: opsLogStore,
        configStore: configStore,
        statsCollector: statsCollector
    )
    private lazy var server = BridgeServer(core: core, host: bindHost())
    private lazy var federationClient = FederationClient(
        eventBus: eventBus,
        core: core,
        configStore: configStore,
        logger: logger
    )
    private lazy var inboundWatcher = LINEInboundWatcher(
        eventBus: eventBus,
        logger: logger,
        pollIntervalSeconds: configStore.load().linePollIntervalSeconds,
        recentSendTracker: recentSendTracker,
        detectionMode: configStore.load().lineDetectionMode,
        fusionThreshold: configStore.load().lineFusionThreshold,
        enablePixelSignal: configStore.load().lineEnablePixelSignal,
        enableProcessSignal: configStore.load().lineEnableProcessSignal,
        enableNotificationStoreSignal: configStore.load().lineEnableNotificationStoreSignal
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
        requestPermissionPromptsIfNeeded()

        do {
            try server.start()
            logger.log(.info, "ClawGate started on \(bindHost()):8765")
        } catch {
            logger.log(.error, "ClawGate failed: \(error)")
        }

        eventBus.subscribe { [weak statsCollector] event in
            statsCollector?.handleEvent(event)
        }
        eventBus.subscribe { [weak self] event in
            self?.persistOpsLogForMenu(event)
        }
        eventBus.subscribe { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.menuBarDelegate?.refreshStatsAndTimeline()
            }
        }

        if configStore.load().nodeRole != .client && configStore.load().lineEnabled {
            inboundWatcher.start()
            notificationBannerWatcher.start()
        } else {
            logger.log(.info, "LINE subsystems are disabled (nodeRole=client or lineEnabled=false)")
        }

        // Start tmux subsystem if enabled
        let config = configStore.load()
        if config.tmuxEnabled {
            startTmuxSubsystem()
        }
        federationClient.start()
    }

    private func requestPermissionPromptsIfNeeded() {
        // Show macOS Accessibility consent prompt if not yet granted.
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            logger.log(.warning, "Requested Accessibility permission prompt")
        }
    }

    func stopServer() {
        if configStore.load().nodeRole != .client && configStore.load().lineEnabled {
            notificationBannerWatcher.stop()
            inboundWatcher.stop()
        }
        tmuxInboundWatcher.stop()
        federationClient.stop()
        ccStatusBarClient.onSessionDetached = nil
        ccStatusBarClient.disconnect()
        server.stop()
        logger.log(.info, "ClawGate stopped")
    }

    private func bindHost() -> String {
        configStore.load().remoteAccessEnabled ? "0.0.0.0" : "127.0.0.1"
    }

    private func enabledAdapters() -> [AdapterProtocol] {
        var adapters: [AdapterProtocol] = [tmuxAdapter]
        if configStore.load().nodeRole != .client && configStore.load().lineEnabled {
            adapters.insert(lineAdapter, at: 0)
        }
        return adapters
    }

    func startTmuxSubsystem() {
        logger.log(.info, "Tmux subsystem starting")
        ccStatusBarClient.setPreferredWebSocketURL(configStore.load().tmuxStatusBarURL)
        ccStatusBarClient.onSessionsChanged = { [weak self] in
            guard let self else { return }
            self.menuBarDelegate?.refreshSessionsMenu(sessions: self.ccStatusBarClient.allSessions())
        }
        ccStatusBarClient.onSessionDetached = { [weak self] session in
            guard let self else { return }
            var config = self.configStore.load()
            let currentMode = config.tmuxSessionModes[session.project] ?? "ignore"
            if currentMode != "ignore" {
                config.tmuxSessionModes[session.project] = "ignore"
                self.configStore.save(config)
                self.logger.log(.info, "Auto-ignored detached session: \(session.project)")
            }
        }
        ccStatusBarClient.connect()
        tmuxInboundWatcher.start()
    }

    private func persistOpsLogForMenu(_ event: BridgeEvent) {
        let role = configStore.load().nodeRole.rawValue
        switch event.type {
        case "federation_status":
            guard event.adapter == "federation" else { return }
            let state = event.payload["state"] ?? "unknown"
            let detail = (event.payload["detail"] ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let short = detail.isEmpty ? "-" : String(detail.prefix(120))
            let level = (state == "connected") ? "info" : (state.contains("fail") || state == "error" ? "error" : "warning")
            opsLogStore.append(
                level: level,
                event: "federation.\(state)",
                role: role,
                script: "clawgate.app",
                message: short
            )
        case "inbound_message":
            guard event.adapter == "tmux" else { return }
            let source = event.payload["source"] ?? ""
            let project = event.payload["project"] ?? "unknown"
            let text = (event.payload["text"] ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let byteCount = text.lengthOfBytes(using: .utf8)
            let short = text.isEmpty ? "(empty)" : String(text.prefix(96))

            switch source {
            case "completion":
                opsLogStore.append(
                    level: "info",
                    event: "tmux.completion",
                    role: role,
                    script: "clawgate.app",
                    message: "project=\(project) bytes=\(byteCount) text=\(short)"
                )
            case "question":
                opsLogStore.append(
                    level: "info",
                    event: "tmux.question",
                    role: role,
                    script: "clawgate.app",
                    message: "project=\(project) bytes=\(byteCount) text=\(short)"
                )
            case "progress":
                opsLogStore.append(
                    level: "debug",
                    event: "tmux.progress",
                    role: role,
                    script: "clawgate.app",
                    message: "project=\(project) bytes=\(byteCount) text=\(short)"
                )
            default:
                break
            }
        case "outbound_message":
            guard event.adapter == "tmux" else { return }
            let project = event.payload["conversation"] ?? "unknown"
            let text = (event.payload["text"] ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let byteCount = text.lengthOfBytes(using: .utf8)
            let short = text.isEmpty ? "(empty)" : String(text.prefix(96))
            opsLogStore.append(
                level: "info",
                event: "tmux.forward",
                role: role,
                script: "clawgate.app",
                message: "project=\(project) bytes=\(byteCount) text=\(short)"
            )
        default:
            break
        }
    }
}

let app = NSApplication.shared
let runtime = AppRuntime()
let delegate = MenuBarAppDelegate(runtime: runtime, statsCollector: runtime.statsCollector, opsLogStore: runtime.opsLogStore)
runtime.menuBarDelegate = delegate
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
