import AppKit
import Foundation

final class AppRuntime {
    let configStore = ConfigStore()
    lazy var statsCollector = StatsCollector()
    lazy var opsLogStore = OpsLogStore()

    private lazy var logger = AppLogger(configStore: configStore)
    private lazy var recentSendTracker = RecentSendTracker()
    private lazy var lineAdapter = LINEAdapter(logger: logger, recentSendTracker: recentSendTracker)

    // Tmux — always route through proxy so the real source can be swapped at startup
    private lazy var ccStatusBarClient = CCStatusBarClient(logger: logger)
    private lazy var tmuxDirectPoller = TmuxDirectPoller(logger: logger)
    private let tmuxSourceProxy = TmuxSessionSourceProxy()
    private lazy var tmuxAdapter = TmuxAdapter(
        ccClient: tmuxSourceProxy,
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
    private lazy var federationServerInstance: FederationServer? = {
        let cfg = configStore.load()
        guard shouldStartFederationServer(cfg) else { return nil }
        return FederationServer(eventBus: eventBus, configStore: configStore, core: core, logger: logger)
    }()
    private lazy var server = BridgeServer(
        core: core,
        host: bindHost(),
        federationServer: federationServerInstance,
        configStore: configStore,
        logger: logger
    )
    private lazy var federationClient = FederationClient(
        eventBus: eventBus,
        core: core,
        configStore: configStore,
        logger: logger
    )
    private lazy var inboundWatcher: LINEInboundWatcher = {
        let cfg = configStore.load()
        return LINEInboundWatcher(
            eventBus: eventBus,
            logger: logger,
            pollIntervalSeconds: cfg.linePollIntervalSeconds,
            recentSendTracker: recentSendTracker,
            detectionMode: cfg.lineDetectionMode,
            fusionThreshold: cfg.lineFusionThreshold,
            enablePixelSignal: cfg.lineEnablePixelSignal,
            enableProcessSignal: cfg.lineEnableProcessSignal,
            enableNotificationStoreSignal: cfg.lineEnableNotificationStoreSignal,
            ocrConfig: VisionOCR.OCRConfig(
                confidenceAccept: Float(cfg.ocrConfidenceAccept),
                confidenceFallback: Float(cfg.ocrConfidenceFallback),
                revision: cfg.ocrRevision,
                usesLanguageCorrection: cfg.ocrUsesLanguageCorrection,
                candidateCount: cfg.ocrCandidateCount
            )
        )
    }()
    private lazy var lineHealthCaretaker = LineHealthCaretaker(
        lineAdapter: lineAdapter,
        inboundWatcher: inboundWatcher,
        recentSendTracker: recentSendTracker,
        configStore: configStore,
        logger: logger
    )
    private lazy var gatewayHealthMonitor = GatewayHealthMonitor(
        core: core,
        logger: logger
    )
    private lazy var notificationBannerWatcher = NotificationBannerWatcher(
        eventBus: eventBus,
        logger: logger,
        recentSendTracker: recentSendTracker
    )
    private lazy var tmuxInboundWatcher = TmuxInboundWatcher(
        ccClient: tmuxSourceProxy,
        eventBus: eventBus,
        logger: logger,
        configStore: configStore
    )

    // Keep a weak reference to the delegate for session menu updates
    weak var menuBarDelegate: MenuBarAppDelegate?

    /// All current CC sessions (for menu refresh).
    func allCCSessions() -> [SessionSnapshot] {
        tmuxSourceProxy.allSessions()
    }

    func autonomousStatusSummary() -> String {
        let snapshot = core.autonomousStatusSnapshot()
        guard !snapshot.targetProject.isEmpty else {
            return "Autonomous: not configured"
        }

        let state: String
        switch snapshot.lastSuppressionReason {
        case "stalled_no_line_send":
            state = "Stalled"
        case "pending_line_send":
            state = "Pending"
        case "line_send_not_local":
            state = "Remote"
        default:
            state = "Active"
        }

        return "Autonomous: \(snapshot.targetProject) / \(snapshot.mode) / \(state)"
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

        // Connect lineInboundWatcher to core for /v1/debug/line-dedup endpoint
        core.lineInboundWatcher = inboundWatcher
        core.lineHealthCaretaker = lineHealthCaretaker

        // Forward petChromeCaptureFired → EventBus (PetModel → Chrome extension poll)
        NotificationCenter.default.addObserver(
            forName: .petChromeCaptureFired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.eventBus.append(type: "chrome_capture_request", adapter: "chrome", payload: [:])
        }

        if configStore.load().lineEnabled {
            inboundWatcher.start()
            lineHealthCaretaker.start()
            notificationBannerWatcher.start()
        } else {
            logger.log(.info, "LINE subsystems are disabled (lineEnabled=false)")
        }

        // Start tmux subsystem (always on — no user toggle).
        let config = configStore.load()
        startTmuxSubsystem()

        // Federation: legacy URL presence decides client-vs-server until Phase C removes federation entirely.
        if shouldStartFederationServer(config) {
            federationServerInstance?.start()
            // Store reference in BridgeCore for command forwarding
            core.federationServer = federationServerInstance
            logger.log(.info, "FederationServer mode: accepting clients on ws://\(bindHost()):8765/federation")
        } else if shouldStartFederationClient(config) {
            federationClient.start()
        }

        // Gateway health monitor: Gateway is the entire purpose of ClawGate.
        core.gatewayHealthMonitor = gatewayHealthMonitor
        gatewayHealthMonitor.start()
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
        if configStore.load().lineEnabled {
            notificationBannerWatcher.stop()
            lineHealthCaretaker.stop()
            inboundWatcher.stop()
        }
        gatewayHealthMonitor.stop()
        tmuxInboundWatcher.stop()
        federationServerInstance?.stop()
        federationClient.stop()
        tmuxSourceProxy.disconnect()
        server.stop()
        logger.log(.info, "ClawGate stopped")
    }

    private func bindHost() -> String {
        "0.0.0.0"
    }

    private func shouldStartFederationServer(_ cfg: AppConfig) -> Bool {
        cfg.federationEnabled && cfg.federationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shouldStartFederationClient(_ cfg: AppConfig) -> Bool {
        cfg.federationEnabled && !cfg.federationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func capabilityRoleLabel() -> String {
        let cfg = configStore.load()
        return "line=\(cfg.lineEnabled) tmux=true remote=true"
    }

    private func enabledAdapters() -> [AdapterProtocol] {
        var adapters: [AdapterProtocol] = [tmuxAdapter]
        if configStore.load().lineEnabled {
            adapters.insert(lineAdapter, at: 0)
        }
        return adapters
    }

    func startTmuxSubsystem() {
        logger.log(.info, "Tmux subsystem starting — built-in direct poller (cc-status-bar decoupled)")

        // Direct-only: the built-in TmuxDirectPoller is the only session source.
        // CCStatusBarClient remains in the tree as a rollback point but is
        // no longer wired into the runtime. cc-status-bar does not need to be
        // running for ClawGate to monitor tmux sessions.
        tmuxSourceProxy.onSessionsChanged = { [weak self] in
            guard let self else { return }
            self.menuBarDelegate?.refreshSessionsMenu(sessions: self.tmuxSourceProxy.allSessions())
        }

        // Start watcher first so its callbacks are installed on the proxy,
        // then swap in the real source (setUnderlying forwards callbacks),
        // then connect. The watcher is source-agnostic.
        tmuxInboundWatcher.start()
        tmuxSourceProxy.setUnderlying(tmuxDirectPoller)
        tmuxSourceProxy.connect()
    }

    private func persistOpsLogForMenu(_ event: BridgeEvent) {
        let role = capabilityRoleLabel()
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
            let traceID = event.payload["trace_id"] ?? ""
            let text = (event.payload["text"] ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let byteCount = text.lengthOfBytes(using: .utf8)
            let short = text.isEmpty ? "(empty)" : String(text.prefix(96))
            let tracePart = traceID.isEmpty ? "" : " trace_id=\(traceID)"

            switch source {
            case "completion":
                opsLogStore.append(
                    level: "info",
                    event: "tmux.completion",
                    role: role,
                    script: "clawgate.app",
                    message: "project=\(project)\(tracePart) bytes=\(byteCount) text=\(short)"
                )
            case "question":
                opsLogStore.append(
                    level: "info",
                    event: "tmux.question",
                    role: role,
                    script: "clawgate.app",
                    message: "project=\(project)\(tracePart) bytes=\(byteCount) text=\(short)"
                )
            case "progress":
                opsLogStore.append(
                    level: "debug",
                    event: "tmux.progress",
                    role: role,
                    script: "clawgate.app",
                    message: "project=\(project)\(tracePart) bytes=\(byteCount) text=\(short)"
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

// Singleton guard: use fcntl F_SETLK to ensure only one ClawGate runs at a time
let singletonLockFD: Int32 = {
    let path = "/tmp/clawgate-singleton.lock"
    let fd = Darwin.open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
        fputs("ClawGate: cannot open lock file. Exiting.\n", stderr)
        Darwin.exit(1)
    }
    var lock = Darwin.flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    if fcntl(fd, F_SETLK, &lock) == -1 {
        fputs("ClawGate: another instance already running. Exiting.\n", stderr)
        Darwin.exit(0)
    }
    _ = Darwin.ftruncate(fd, 0)
    let pid = "\(ProcessInfo.processInfo.processIdentifier)"
    pid.utf8CString.withUnsafeBufferPointer { buf in
        _ = Darwin.write(fd, buf.baseAddress!, buf.count - 1)
    }
    return fd
}()
_ = singletonLockFD  // keep FD open for process lifetime

if #available(macOS 13.0, *) {
    LaunchAtLoginManager.shared.migrateLegacyLaunchAgentIfNeeded { level, message in
        fputs("ClawGate startup [\(level.rawValue.uppercased())] \(message)\n", stderr)
    }
}

let runtime = AppRuntime()
let delegate = MenuBarAppDelegate(runtime: runtime, statsCollector: runtime.statsCollector, opsLogStore: runtime.opsLogStore)
runtime.menuBarDelegate = delegate
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
