import AppKit
import SwiftUI

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var qrCodeWindow: NSWindow?
    private var ccSessionsMenu: NSMenu?
    private var settingsSubmenu: NSMenu?
    private var todayStatsItem: NSMenuItem?
    private var timelineSeparatorItem: NSMenuItem?
    private var recentEventItems: [NSMenuItem] = []
    private var timelineEndSeparatorItem: NSMenuItem?

    private let runtime: AppRuntime
    private let statsCollector: StatsCollector
    private let settingsModel: SettingsModel

    init(runtime: AppRuntime, statsCollector: StatsCollector) {
        self.runtime = runtime
        self.statsCollector = statsCollector
        self.settingsModel = SettingsModel(configStore: runtime.configStore)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()

        // Today stats (info-only)
        let statsItem = NSMenuItem(title: "Today: 0 sent, 0 received", action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        menu.addItem(statsItem)
        self.todayStatsItem = statsItem

        // Timeline separator + recent events
        let tlSep = NSMenuItem.separator()
        menu.addItem(tlSep)
        self.timelineSeparatorItem = tlSep

        let noEvents = NSMenuItem(title: "  No recent events", action: nil, keyEquivalent: "")
        noEvents.isEnabled = false
        menu.addItem(noEvents)
        self.recentEventItems = [noEvents]

        let tlEndSep = NSMenuItem.separator()
        menu.addItem(tlEndSep)
        self.timelineEndSeparatorItem = tlEndSep

        // Show QR Code item
        let qrCodeItem = NSMenuItem(title: "Show QR Code...", action: #selector(openQRCodeWindow), keyEquivalent: "r")
        qrCodeItem.target = self
        menu.addItem(qrCodeItem)

        menu.addItem(NSMenuItem.separator())

        // Claude Code Sessions submenu
        let sessionsItem = NSMenuItem(title: "Claude Code Sessions", action: nil, keyEquivalent: "")
        let sessionsMenu = NSMenu(title: "Claude Code Sessions")
        let placeholderItem = NSMenuItem(title: "Connecting...", action: nil, keyEquivalent: "")
        placeholderItem.isEnabled = false
        sessionsMenu.addItem(placeholderItem)
        sessionsItem.submenu = sessionsMenu
        menu.addItem(sessionsItem)
        self.ccSessionsMenu = sessionsMenu

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "Settings")
        let settingsViewItem = NSMenuItem()
        let hostingView = NSHostingView(rootView: InlineSettingsView(model: settingsModel))
        hostingView.frame.size = hostingView.fittingSize
        settingsViewItem.view = hostingView
        settingsMenu.addItem(settingsViewItem)
        settingsMenu.delegate = self
        settingsItem.submenu = settingsMenu
        self.settingsSubmenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        runtime.startServer()
        refreshStatsAndTimeline()
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
        }
    }

    /// Called by AppRuntime after CCStatusBarClient updates sessions.
    func refreshSessionsMenu(sessions: [CCStatusBarClient.CCSession]) {
        guard let menu = ccSessionsMenu else { return }

        // Must update menu on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateStatusIcon()
            menu.removeAllItems()

            if sessions.isEmpty {
                let item = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                return
            }

            let config = self.runtime.configStore.load()
            let modes = config.tmuxSessionModes

            for session in sessions {
                let mode = modes[session.project] ?? "ignore"

                let statusIcon: String
                if mode == "ignore" {
                    statusIcon = "\u{25CB}" // ○ (always neutral for ignored)
                } else {
                    switch session.status {
                    case "running": statusIcon = "\u{25B6}" // ▶
                    case "waiting_input": statusIcon = "\u{25CF}" // ●
                    default: statusIcon = "\u{25CB}" // ○
                    }
                }

                let title = "\(statusIcon) \(session.project)"
                let sessionItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                sessionItem.image = self.modeImage(for: mode)

                // Build mode submenu with radio-style selection
                let modeSubmenu = NSMenu()

                let modeOptions: [(label: String, value: String, tag: Int, symbol: String)] = [
                    ("Autonomous", "autonomous", 3, "bolt.fill"),
                    ("Simple Auto", "auto", 2, "gearshape"),
                    ("Observe", "observe", 1, "eye"),
                    ("Ignore", "ignore", 0, "minus"),
                ]

                for opt in modeOptions {
                    let modeItem = NSMenuItem(title: opt.label, action: #selector(self.setSessionMode(_:)), keyEquivalent: "")
                    modeItem.target = self
                    modeItem.tag = opt.tag
                    modeItem.representedObject = session.project
                    modeItem.state = (mode == opt.value) ? .on : .off
                    modeItem.image = NSImage(systemSymbolName: opt.symbol, accessibilityDescription: opt.label)
                    modeSubmenu.addItem(modeItem)
                }

                sessionItem.submenu = modeSubmenu
                menu.addItem(sessionItem)
            }
        }
    }

    private func modeImage(for mode: String) -> NSImage? {
        let name: String
        switch mode {
        case "autonomous": name = "bolt.fill"
        case "auto": name = "gearshape"
        case "observe": name = "eye"
        default: name = "minus"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: mode)
    }

    /// Set session mode directly from submenu selection.
    @objc private func setSessionMode(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? String else { return }

        let newMode: String?
        switch sender.tag {
        case 3: newMode = "autonomous"
        case 2: newMode = "auto"
        case 1: newMode = "observe"
        default: newMode = nil // ignore = remove from dict
        }

        var config = runtime.configStore.load()

        if let mode = newMode {
            config.tmuxSessionModes[project] = mode
        } else {
            config.tmuxSessionModes.removeValue(forKey: project)
        }

        runtime.configStore.save(config)
        updateStatusIcon()

        // Refresh menu to reflect new state
        refreshSessionsMenu(sessions: runtime.allCCSessions())
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let mode = dominantSessionMode()
        let dotColor: NSColor
        switch mode {
        case "autonomous":
            dotColor = NSColor.systemRed
        case "auto":
            dotColor = NSColor.systemOrange
        case "observe":
            dotColor = NSColor.systemBlue
        default:
            dotColor = NSColor.systemGray
        }

        let crab = NSAttributedString(string: "🦀 ", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
        ])
        let dot = NSAttributedString(string: "●", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: dotColor,
        ])
        let title = NSMutableAttributedString()
        title.append(crab)
        title.append(dot)
        button.attributedTitle = title
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
        let stats = statsCollector.today()
        var title = "Today: \(stats.lineSent) sent, \(stats.lineReceived) received"
        let tmuxTotal = stats.tmuxSent + stats.tmuxCompletion
        if tmuxTotal > 0 {
            title += " \u{00B7} \(stats.tmuxSent) tasks"
        }
        todayStatsItem?.title = title

        // Update timeline
        guard let menu = statusItem?.menu,
              let endSep = timelineEndSeparatorItem,
              let endIdx = menu.items.firstIndex(of: endSep) else { return }

        // Remove old event items
        for item in recentEventItems {
            menu.removeItem(item)
        }
        recentEventItems.removeAll()

        let events = statsCollector.recentTimeline(count: 5)
        var insertIdx = endIdx

        if events.isEmpty {
            let item = NSMenuItem(title: "  No recent events", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: insertIdx)
            recentEventItems.append(item)
        } else {
            for event in events {
                let timeStr = Self.timeFormatter.string(from: event.timestamp)
                let preview = event.textPreview.prefix(30)
                let truncated = preview.count < event.textPreview.count ? "\(preview)..." : String(preview)
                let itemTitle: String
                if truncated.isEmpty {
                    itemTitle = "  \(timeStr)  \(event.icon) \(event.label)"
                } else {
                    itemTitle = "  \(timeStr)  \(event.icon) \(event.label) \"\(truncated)\""
                }
                let item = NSMenuItem(title: itemTitle, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.insertItem(item, at: insertIdx)
                recentEventItems.append(item)
                insertIdx += 1
            }
        }
    }

    @objc private func quit() {
        runtime.stopServer()
        NSApplication.shared.terminate(nil)
    }
}
