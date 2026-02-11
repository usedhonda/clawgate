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

        // 2) Claude Code sessions (direct list, no submenu)
        menu.addItem(makeReadableInfoItem("Claude Code Sessions"))
        let noSessions = makeReadableInfoItem("  No active sessions")
        menu.addItem(noSessions)
        sessionItems = [noSessions]
        let sessionsEnd = NSMenuItem.separator()
        menu.addItem(sessionsEnd)
        sessionsEndSeparatorItem = sessionsEnd

        // 3) QR
        let qrCodeItem = NSMenuItem(title: "Show QR Code...", action: #selector(openQRCodeWindow), keyEquivalent: "r")
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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "OpenClaw Connection"
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

            for item in self.sessionItems {
                menu.removeItem(item)
            }
            self.sessionItems.removeAll()

            guard let endIdx = menu.items.firstIndex(of: endSep) else { return }
            var insertIdx = endIdx
            if sessions.isEmpty {
                let item = self.makeReadableInfoItem("  No active sessions")
                menu.insertItem(item, at: insertIdx)
                self.sessionItems = [item]
                return
            }

            let modes = self.runtime.configStore.load().tmuxSessionModes
            for session in sessions {
                let mode = modes[session.project] ?? "ignore"
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
                let title = "  \(statusIcon) \(session.project) [\(mode)]"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = self.makeSessionModeSubmenu(project: session.project, currentMode: mode)
                self.applyReadableTitle(to: item, text: title)
                menu.insertItem(item, at: insertIdx)
                self.sessionItems.append(item)
                insertIdx += 1
            }
        }
    }

    private func makeSessionModeSubmenu(project: String, currentMode: String) -> NSMenu {
        let submenu = NSMenu(title: project)
        for mode in modeOrder {
            let label = "  \(modeLabel(mode))"
            let item = NSMenuItem(title: label, action: #selector(setSessionMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "\(project)\t\(mode)"
            item.state = (mode == currentMode) ? .on : .off
            applyReadableTitle(to: item, text: label)
            submenu.addItem(item)
        }
        return submenu
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
        let parts = raw.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let project = parts[0]
        let next = parts[1]

        var config = runtime.configStore.load()
        if next == "ignore" {
            config.tmuxSessionModes.removeValue(forKey: project)
        } else {
            config.tmuxSessionModes[project] = next
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
            let icon: String
            switch entry.level.lowercased() {
            case "error":
                icon = "✖"
            case "warning", "warn":
                icon = "▲"
            default:
                icon = "•"
            }
            let t = Self.timeFormatter.string(from: entry.date)
            let text = compactMessage(entry.message, max: 52)
            let item = makeReadableInfoItem("  \(t) \(icon) \(entry.event) \(text)")
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

    private func applyReadableTitle(to item: NSMenuItem?, text: String, emphasis: Bool = false) {
        guard let item else { return }
        let weight: NSFont.Weight = emphasis ? .semibold : .medium
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: weight),
            .foregroundColor: NSColor.controlTextColor,
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
