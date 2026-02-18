import AppKit
import SwiftUI

private extension NSColor {
    /// Bright light-gray for default log text — always readable on a dark panel background.
    static let logDefault = NSColor(white: 0.82, alpha: 1.0)
    /// Dimmer gray for "no logs" placeholder text.
    static let logDim = NSColor(white: 0.55, alpha: 1.0)
}

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainPanel: NSPanel?
    private var mainPanelHost: NSHostingController<MainPanelView>?
    private var refreshTimer: Timer?
    private let mainPanelLogLimit = 30

    private let modeOrder: [String] = ["ignore", "observe", "auto", "autonomous"]

    private let runtime: AppRuntime
    private let statsCollector: StatsCollector
    private let opsLogStore: OpsLogStore
    private let settingsModel: SettingsModel
    private let panelModel = MainPanelModel()

    init(runtime: AppRuntime, statsCollector: StatsCollector, opsLogStore: OpsLogStore) {
        self.runtime = runtime
        self.statsCollector = statsCollector
        self.opsLogStore = opsLogStore
        self.settingsModel = SettingsModel(configStore: runtime.configStore)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        configureStatusButton()
        configureMainPanel()

        runtime.startServer()
        refreshSessionsMenu(sessions: runtime.allCCSessions())
        refreshStatsAndTimeline()
        startRefreshTimer()
    }

    private func configureStatusButton() {
        guard let button = statusItem?.button else { return }
        button.target = self
        button.action = #selector(toggleMainPanel(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureMainPanel() {
        let view = MainPanelView(
            settingsModel: settingsModel,
            panelModel: panelModel,
            modeOrder: modeOrder,
            modeLabel: { [weak self] mode in
                self?.modeLabel(mode) ?? mode.capitalized
            },
            onSetSessionMode: { [weak self] sessionType, project, mode in
                self?.setSessionMode(sessionType: sessionType, project: project, next: mode)
            },
            onQuit: { [weak self] in
                self?.quit()
            },
            logLimit: mainPanelLogLimit
        )
        let host = NSHostingController(rootView: view)
        mainPanelHost = host

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = PanelTheme.backgroundNSColor
        panel.isOpaque = false
        panel.contentViewController = host
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 300)
        panel.maxSize = NSSize(width: 700, height: 1400)
        mainPanel = panel
    }

    private func fitPanelToContent(_ panel: NSPanel) {
        guard let host = mainPanelHost else { return }
        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize

        let w = min(max(fitting.width, panel.minSize.width), panel.maxSize.width)

        let screenMaxH: CGFloat
        if let screen = NSScreen.main {
            screenMaxH = screen.visibleFrame.height - 28
        } else {
            screenMaxH = panel.maxSize.height
        }
        // 580: enough to show QR code section when switching to Config tab
        let minH = max(panel.minSize.height, 580)
        let h = min(max(fitting.height, minH), min(panel.maxSize.height, screenMaxH))

        panel.setContentSize(NSSize(width: w, height: h))
    }

    @objc private func toggleMainPanel(_ sender: Any?) {
        guard let panel = mainPanel else { return }

        if panel.isVisible {
            closeMainPanel(sender)
            return
        }

        settingsModel.reload()
        refreshSessionsMenu(sessions: runtime.allCCSessions())
        refreshStatsAndTimeline()
        fitPanelToContent(panel)
        positionPanelBelowStatusItem(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func positionPanelBelowStatusItem(_ panel: NSPanel) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let panelSize = panel.frame.size
        let x = screenRect.midX - panelSize.width / 2
        let y = screenRect.minY - panelSize.height - 4
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let clampedX = max(visibleFrame.minX + 8, min(x, visibleFrame.maxX - panelSize.width - 8))
            let clampedY = max(visibleFrame.minY + 8, y)
            panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    /// Called by AppRuntime after CCStatusBarClient updates sessions.
    func refreshSessionsMenu(sessions: [CCStatusBarClient.CCSession]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateStatusIcon()
            let deduped = self.deduplicateByProject(sessions)
            let sorted = deduped.sorted {
                $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending
            }
            self.panelModel.codexSessions = sorted.filter { $0.sessionType == "codex" }
            self.panelModel.claudeSessions = sorted.filter { $0.sessionType == "claude_code" }
            self.panelModel.sessionModes = self.runtime.configStore.load().tmuxSessionModes
        }
    }

    /// Deduplicate sessions by (sessionType, project): keep the most-active one.
    /// Priority: running (2) > waiting_input (1) > other (0)
    private func deduplicateByProject(
        _ sessions: [CCStatusBarClient.CCSession]
    ) -> [CCStatusBarClient.CCSession] {
        let priority = ["running": 2, "waiting_input": 1]
        var best: [String: CCStatusBarClient.CCSession] = [:]
        for session in sessions {
            let key = "\(session.sessionType):\(session.project)"
            if let existing = best[key] {
                let ep = priority[existing.status] ?? 0
                let np = priority[session.status] ?? 0
                if np > ep { best[key] = session }
            } else {
                best[key] = session
            }
        }
        return Array(best.values)
    }

    private func setSessionMode(sessionType: String, project: String, next: String) {
        let key = AppConfig.modeKey(sessionType: sessionType, project: project)
        var config = runtime.configStore.load()
        if next == "ignore" {
            config.tmuxSessionModes.removeValue(forKey: key)
        } else {
            config.tmuxSessionModes[key] = next
        }
        runtime.configStore.save(config)
        refreshSessionsMenu(sessions: runtime.allCCSessions())
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let mode = dominantSessionMode()
        let dotColor: NSColor
        switch mode {
        case "autonomous":
            dotColor = .systemRed
        case "auto":
            dotColor = .systemOrange
        case "observe":
            dotColor = .systemBlue
        default:
            dotColor = .systemGray
        }

        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = statusIconImage(dotColor: dotColor)
        button.imagePosition = .imageOnly
    }

    private func statusIconImage(dotColor: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let crabRect = NSRect(x: 1, y: 0, width: 16, height: 16)
        let crabStyle = NSMutableParagraphStyle()
        crabStyle.alignment = .center
        let crabAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .paragraphStyle: crabStyle,
        ]
        ("🦀" as NSString).draw(in: crabRect, withAttributes: crabAttributes)

        let badgeRect = NSRect(x: 13, y: 1, width: 8, height: 8)
        let badgePath = NSBezierPath(ovalIn: badgeRect)
        dotColor.setFill()
        badgePath.fill()
        NSColor.white.setStroke()
        badgePath.lineWidth = 1.0
        badgePath.stroke()

        image.isTemplate = false
        return image
    }

    private func dominantSessionMode() -> String {
        let modes = runtime.configStore.load().tmuxSessionModes.values
        if modes.contains("autonomous") { return "autonomous" }
        if modes.contains("auto") { return "auto" }
        if modes.contains("observe") { return "observe" }
        return "ignore"
    }

    private func modeLabel(_ mode: String) -> String {
        switch mode {
        case "ignore": return "Ignore"
        case "observe": return "Observe"
        case "auto": return "Auto"
        case "autonomous": return "Autonomous"
        default: return mode.capitalized
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    func refreshStatsAndTimeline() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let entries = self.opsLogStore.recent(limit: self.mainPanelLogLimit)
            if entries.isEmpty {
                let now = Self.timeFormatter.string(from: Date())
                self.panelModel.logs = [
                    MainPanelLogLine(text: "\(now) • No recent logs", color: .logDim, event: ""),
                ]
                return
            }

            let rawLines = entries.map { entry in
                let t = Self.timeFormatter.string(from: entry.date)
                let style = self.compactLogStyle(for: entry)
                return MainPanelLogLine(text: "\(t) \(style.text)", color: style.color, event: entry.event)
            }
            self.panelModel.logs = deduplicateRuns(rawLines)
        }
    }

    /// Collapse consecutive runs of the same `event` into one line with "×N" suffix.
    /// Input is newest-first (as returned by opsLogStore.recent).
    private func deduplicateRuns(_ lines: [MainPanelLogLine]) -> [MainPanelLogLine] {
        var result: [MainPanelLogLine] = []
        var i = 0
        while i < lines.count {
            let current = lines[i]
            var runCount = 1
            // Count how many consecutive entries share the same event key
            while i + runCount < lines.count && lines[i + runCount].event == current.event && !current.event.isEmpty {
                runCount += 1
            }
            if runCount >= 2 {
                let collapsed = MainPanelLogLine(
                    text: current.text + " \u{00D7}\(runCount)",
                    color: current.color,
                    event: current.event
                )
                result.append(collapsed)
            } else {
                result.append(current)
            }
            i += runCount
        }
        return result
    }

    private func compactMessage(_ text: String, max: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        if single.count <= max { return single }
        return String(single.prefix(max)) + "..."
    }

    private func humanReadableSummary(for entry: OpsLogEntry) -> String {
        let fields = parseMessageFields(entry.message)
        let project = shortProject(fields.project)
        let bytes = fields.bytes.map { "\($0)b" } ?? "-b"
        let preview = compactMessage(fields.text, max: 32)

        switch entry.event {
        case "federation.connected":
            return "FED UP \(compactMessage(entry.message, max: 32))"
        case "federation.connecting":
            return "FED CONNECT \(compactMessage(entry.message, max: 28))"
        case "federation.closed":
            return "FED CLOSED \(compactMessage(entry.message, max: 24))"
        case "federation.receive_failed", "federation.send_failed", "federation.error":
            return "FED ERR \(compactMessage(entry.message, max: 28))"
        case "federation.disabled", "federation.invalid_url":
            return "FED OFF \(compactMessage(entry.message, max: 28))"
        case "tmux.completion":
            return "CAP DONE \(project) \(bytes) \(preview)"
        case "tmux.question":
            return "CAP Q \(project) \(bytes) \(preview)"
        case "tmux.progress":
            return "CAP PROG \(project) \(bytes) \(preview)"
        case "tmux.forward":
            return "FWD \(project) \(bytes) \(preview)"
        case "tmux_gateway_deliver":
            return "ACK \(project)"
        case "line_send_ok":
            return "MSG OUT OK"
        case "line_send_start":
            return "MSG SEND"
        case "send_failed":
            let parts = parseKeyValueMessage(entry.message)
            let code = parts["error_code"] ?? "unknown"
            let msg = compactMessage(parts["error_message"] ?? "", max: 32)
            return "ERR \(project) \(code) \(msg)"
        case "ingress_received":
            return "SRV IN"
        case "ingress_validated":
            return "SRV VALID"
        default:
            let fallback = compactMessage(entry.message, max: 40)
            if fallback.isEmpty {
                return entry.event
            }
            return "\(entry.event) \(fallback)"
        }
    }

    private struct ParsedMessageFields {
        let project: String?
        let bytes: Int?
        let text: String
    }

    private func parseMessageFields(_ message: String) -> ParsedMessageFields {
        let kv = parseKeyValueMessage(message)
        let project = kv["project"]
        let bytes = kv["bytes"].flatMap(Int.init)

        let text: String
        if let range = message.range(of: "text=") {
            text = String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = ""
        }
        return ParsedMessageFields(project: project, bytes: bytes, text: text)
    }

    private func parseKeyValueMessage(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        let tokens = message.split(separator: " ")
        for token in tokens {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
            if !key.isEmpty && !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private func shortProject(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "-" }
        return String(trimmed.prefix(16))
    }

    private func compactLogStyle(for entry: OpsLogEntry) -> (text: String, color: NSColor) {
        let text = humanReadableSummary(for: entry)
        switch entry.event {
        case "federation.connected":
            return (text, .systemGreen)
        case "federation.connecting":
            return (text, .systemBlue)
        case "federation.closed", "federation.receive_failed", "federation.send_failed", "federation.error":
            return (text, .systemRed)
        case "federation.disabled", "federation.invalid_url":
            return (text, .systemOrange)
        case "tmux.completion", "tmux.question", "tmux.progress":
            return (text, .logDefault)
        case "line_send_ok":
            return (text, .systemGreen)
        case "line_send_start":
            return (text, .systemBlue)
        case "tmux.forward":
            return (text, .systemBlue)
        case "tmux_gateway_deliver":
            return (text, .systemPurple)
        case "ingress_received", "ingress_validated":
            return (text, .systemPurple)
        case "send_failed", "decode_failed":
            return (text, .systemRed)
        default:
            if entry.level.lowercased() == "error" {
                return (text, .systemRed)
            }
            return (text, .logDefault)
        }
    }

    @objc private func quit() {
        closeMainPanel(nil)
        refreshTimer?.invalidate()
        refreshTimer = nil
        runtime.stopServer()
        NSApplication.shared.terminate(nil)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshStatsAndTimeline()
            self?.refreshSessionsMenu(sessions: self?.runtime.allCCSessions() ?? [])
        }
    }

    private func closeMainPanel(_ sender: Any?) {
        guard let panel = mainPanel, panel.isVisible else { return }
        panel.orderOut(sender)
    }
}
