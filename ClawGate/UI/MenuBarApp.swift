import AppKit
import SwiftUI

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var qrCodeWindow: NSWindow?
    private var ccSessionsMenu: NSMenu?

    private let runtime: AppRuntime

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🦀"

        let menu = NSMenu()

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

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        runtime.startServer()
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

    @objc private func openSettings() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(configStore: runtime.configStore)
        let content = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "ClawGate"
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    /// Called by AppRuntime after CCStatusBarClient updates sessions.
    func refreshSessionsMenu(sessions: [CCStatusBarClient.CCSession]) {
        guard let menu = ccSessionsMenu else { return }

        // Must update menu on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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
                    ("Autonomous", "autonomous", 2, "bolt.fill"),
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
        case 2: newMode = "autonomous"
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

        // Refresh menu to reflect new state
        refreshSessionsMenu(sessions: runtime.allCCSessions())
    }

    @objc private func quit() {
        runtime.stopServer()
        NSApplication.shared.terminate(nil)
    }
}
