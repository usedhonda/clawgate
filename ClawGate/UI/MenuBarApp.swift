import AppKit
import SwiftUI

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var qrCodeWindow: NSWindow?
    private var settingsSubmenu: NSMenu?
    private var settingsViewItem: NSMenuItem?
    private var settingsHostingView: NSHostingView<InlineSettingsView>?

    private var sessionItems: [NSMenuItem] = []
    private var sessionsEndSeparatorItem: NSMenuItem?

    private var codexHeaderItem: NSMenuItem?
    private var codexSessionItems: [NSMenuItem] = []

    private var logItems: [NSMenuItem] = []
    private var logsEndSeparatorItem: NSMenuItem?

    private var refreshTimer: Timer?
    private let modeOrder: [String] = ["ignore", "observe", "auto", "autonomous"]

    private let runtime: AppRuntime
    private let statsCollector: StatsCollector
    private let opsLogStore: OpsLogStore
    private let settingsModel: SettingsModel

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

        let menu = NSMenu()

        // 1) Settings (top)
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "Settings")
        let settingsInlineItem = NSMenuItem()
        let hostingView = NSHostingView(rootView: InlineSettingsView(model: settingsModel))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.frame.size = hostingView.fittingSize
        settingsInlineItem.view = hostingView
        settingsMenu.addItem(settingsInlineItem)
        settingsMenu.delegate = self
        settingsItem.submenu = settingsMenu
        settingsSubmenu = settingsMenu
        settingsViewItem = settingsInlineItem
        settingsHostingView = hostingView
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // 2) Tmux sessions (Codex first, then CC)
        menu.addItem(makeReadableInfoItem("Codex Sessions"))
        let noSessions = makeReadableInfoItem("  No active sessions")
        menu.addItem(noSessions)
        sessionItems = [noSessions]
        let sessionsEnd = NSMenuItem.separator()
        menu.addItem(sessionsEnd)
        sessionsEndSeparatorItem = sessionsEnd

        // 3) QR
        let qrCodeItem = NSMenuItem(title: "Show QR Code for [VibeTerm]", action: #selector(openQRCodeWindow), keyEquivalent: "r")
        qrCodeItem.target = self
        menu.addItem(qrCodeItem)

        menu.addItem(NSMenuItem.separator())

        // 4) Logs (last content section)
        menu.addItem(makeReadableInfoItem("Ops Logs (latest 10)"))
        let initialLogTime = Self.timeFormatter.string(from: Date())
        let noLogs = makeReadableInfoItem("  \(initialLogTime) • No recent logs")
        menu.addItem(noLogs)
        logItems = [noLogs]
        let logsEnd = NSMenuItem.separator()
        menu.addItem(logsEnd)
        logsEndSeparatorItem = logsEnd

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        runtime.startServer()
        refreshStatsAndTimeline()
        startRefreshTimer()
    }

    @objc private func openQRCodeWindow() {
        if let w = qrCodeWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = QRCodeView()
        let content = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "VibeTerm"
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        qrCodeWindow = window
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if menu === settingsSubmenu {
            settingsModel.reload()
            if let hostingView = settingsHostingView, let item = settingsViewItem {
                hostingView.layoutSubtreeIfNeeded()
                hostingView.frame.size = hostingView.fittingSize
                item.view = hostingView
            }
        }
    }

    /// Called by AppRuntime after CCStatusBarClient updates sessions.
    func refreshSessionsMenu(sessions: [CCStatusBarClient.CCSession]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let menu = self.statusItem?.menu,
                  let endSep = self.sessionsEndSeparatorItem else { return }

            self.updateStatusIcon()

            // Remove old CC session items
            for item in self.sessionItems {
                menu.removeItem(item)
            }
            self.sessionItems.removeAll()

            // Remove old Codex items (header + session rows)
            for item in self.codexSessionItems {
                menu.removeItem(item)
            }
            self.codexSessionItems.removeAll()
            if let header = self.codexHeaderItem {
                menu.removeItem(header)
                self.codexHeaderItem = nil
            }

            guard let endIdx = menu.items.firstIndex(of: endSep) else { return }

            let ccSessions = sessions.filter { $0.sessionType == "claude_code" }
            let codexSessions = sessions.filter { $0.sessionType == "codex" }
            let modes = self.runtime.configStore.load().tmuxSessionModes

            // --- Codex section (top, under static "Codex Sessions" header) ---
            var insertIdx = endIdx
            if codexSessions.isEmpty {
                let item = self.makeReadableInfoItem("  No active sessions")
                menu.insertItem(item, at: insertIdx)
                self.codexSessionItems = [item]
                insertIdx += 1
            } else {
                for session in codexSessions {
                    let item = self.makeSessionMenuItem(session: session, modes: modes)
                    menu.insertItem(item, at: insertIdx)
                    self.codexSessionItems.append(item)
                    insertIdx += 1
                }
            }

            // --- CC section (below Codex) ---
            if !ccSessions.isEmpty {
                let header = self.makeReadableInfoItem("Claude Code Sessions")
                menu.insertItem(header, at: insertIdx)
                self.codexHeaderItem = header
                insertIdx += 1

                for session in ccSessions {
                    let item = self.makeSessionMenuItem(session: session, modes: modes)
                    menu.insertItem(item, at: insertIdx)
                    self.sessionItems.append(item)
                    insertIdx += 1
                }
            }
        }
    }

    private func makeSessionMenuItem(session: CCStatusBarClient.CCSession, modes: [String: String]) -> NSMenuItem {
        let mode = modes[AppConfig.modeKey(sessionType: session.sessionType, project: session.project)] ?? "ignore"
        let statusIcon: String
        if mode == "ignore" {
            statusIcon = "○"
        } else {
            switch session.status {
            case "running":
                statusIcon = "▶"
            case "waiting_input":
                statusIcon = "●"
            default:
                statusIcon = "○"
            }
        }
        let prefix = "  \(statusIcon) \(session.project) "
        let modeText = "[\(mode)]"
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let attr = NSMutableAttributedString(
            string: prefix,
            attributes: [.font: font, .foregroundColor: NSColor.controlTextColor]
        )
        attr.append(NSAttributedString(
            string: modeText,
            attributes: [.font: font, .foregroundColor: modeColor(mode)]
        ))
        let item = NSMenuItem(title: prefix + modeText, action: nil, keyEquivalent: "")
        item.attributedTitle = attr
        item.submenu = makeSessionModeSubmenu(sessionType: session.sessionType, project: session.project, currentMode: mode)
        return item
    }

    private func makeSessionModeSubmenu(sessionType: String, project: String, currentMode: String) -> NSMenu {
        let submenu = NSMenu(title: project)
        for mode in modeOrder {
            let label = "  \(modeLabel(mode))"
            let item = NSMenuItem(title: label, action: #selector(setSessionMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "\(sessionType)\t\(project)\t\(mode)"
            item.state = (mode == currentMode) ? .on : .off
            applyReadableTitle(to: item, text: label, color: modeColor(mode))
            submenu.addItem(item)
        }
        return submenu
    }

    private func modeColor(_ mode: String) -> NSColor {
        switch mode {
        case "autonomous": return .systemRed
        case "auto":       return .systemOrange
        case "observe":    return .systemBlue
        default:           return .labelColor
        }
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

    @objc private func setSessionMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "\t", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        let sessionType = parts[0]
        let project = parts[1]
        let next = parts[2]
        let key = AppConfig.modeKey(sessionType: sessionType, project: project)

        var config = runtime.configStore.load()
        if next == "ignore" {
            config.tmuxSessionModes.removeValue(forKey: key)
        } else {
            config.tmuxSessionModes[key] = next
        }
        runtime.configStore.save(config)
        updateStatusIcon()
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    func refreshStatsAndTimeline() {
        guard let menu = statusItem?.menu,
              let endSep = logsEndSeparatorItem else { return }

        for item in logItems {
            menu.removeItem(item)
        }
        logItems.removeAll()

        guard let endIdx = menu.items.firstIndex(of: endSep) else { return }
        var insertIdx = endIdx
        let entries = opsLogStore.recent(limit: 10)

        if entries.isEmpty {
            let now = Self.timeFormatter.string(from: Date())
            let item = makeReadableInfoItem("  \(now) • No recent logs")
            menu.insertItem(item, at: insertIdx)
            logItems = [item]
            return
        }

        for entry in entries {
            let t = Self.timeFormatter.string(from: entry.date)
            let style = compactLogStyle(for: entry)
            let item = makeReadableInfoItem("  \(t) \(style.text)")
            applyReadableTitle(to: item, text: "  \(t) \(style.text)", color: style.color)
            menu.insertItem(item, at: insertIdx)
            logItems.append(item)
            insertIdx += 1
        }
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
            return "LINE OK"
        case "line_send_start":
            return "LINE SEND"
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

        // Preserve full text after "text=" including spaces.
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
            return (text, .labelColor) // captured only
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
            return (text, .labelColor)
        }
    }

    @objc private func quit() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        runtime.stopServer()
        NSApplication.shared.terminate(nil)
    }

    @objc private func noopInfoItem(_ sender: NSMenuItem) {
        // Intentionally no-op. Keeps info rows visually enabled/readable.
    }

    private func makeReadableInfoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(noopInfoItem(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        applyReadableTitle(to: item, text: title)
        return item
    }

    private func applyReadableTitle(to item: NSMenuItem?, text: String, emphasis: Bool = false, color: NSColor = .controlTextColor) {
        guard let item else { return }
        let weight: NSFont.Weight = emphasis ? .semibold : .medium
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: weight),
            .foregroundColor: color,
        ])
        item.attributedTitle = attributed
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshStatsAndTimeline()
            self?.refreshSessionsMenu(sessions: self?.runtime.allCCSessions() ?? [])
        }
    }
}
