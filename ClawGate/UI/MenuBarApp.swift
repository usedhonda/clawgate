import AppKit
import SwiftUI

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var pairingMenuItem: NSMenuItem?
    private var pairingTimer: Timer?

    private let runtime: AppRuntime

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🦀"

        let menu = NSMenu()
        menu.delegate = self

        // Pairing code item
        pairingMenuItem = NSMenuItem(title: "Generate Pairing Code", action: #selector(generatePairingCode), keyEquivalent: "p")
        pairingMenuItem?.target = self
        menu.addItem(pairingMenuItem!)

        // Copy token item
        let copyTokenItem = NSMenuItem(title: "Copy Token", action: #selector(copyToken), keyEquivalent: "t")
        copyTokenItem.target = self
        menu.addItem(copyTokenItem)

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

    @objc private func generatePairingCode() {
        let code = runtime.pairingManager.generateCode()

        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        // Update menu item to show code and countdown
        updatePairingMenuItem()

        // Start countdown timer
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updatePairingMenuItem()
        }
    }

    private func updatePairingMenuItem() {
        let remaining = runtime.pairingManager.remainingSeconds()

        if remaining > 0, let code = runtime.pairingManager.currentValidCode() {
            pairingMenuItem?.title = "📋 \(code) (\(remaining)s)"
        } else {
            pairingMenuItem?.title = "Generate Pairing Code"
            pairingTimer?.invalidate()
            pairingTimer = nil
        }
    }

    @objc private func copyToken() {
        let token = runtime.tokenManager.currentToken()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }

    @objc private func openSettings() {
        let view = SettingsView(configStore: runtime.configStore, tokenManager: runtime.tokenManager)
        let content = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClawGate"
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func quit() {
        runtime.stopServer()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarAppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Refresh pairing code display when menu opens
        updatePairingMenuItem()
    }
}
