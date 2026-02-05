import AppKit
import ApplicationServices
import Foundation

enum AXActions {
    static func setValue(_ text: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func setFocused(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    static func confirmEnterFallback() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Micro-foreground

    /// Try AXFocused first; if that fails, briefly activate the target app,
    /// perform the action, then restore the previously-active app.
    static func withFocus(
        on element: AXUIElement,
        bundleIdentifier: String,
        action: () -> Void
    ) {
        // Attempt background focus via AXFocused attribute
        if setFocused(element) {
            action()
            return
        }

        // Micro-foreground: activate target, run action, restore
        let previousApp = NSWorkspace.shared.frontmostApplication
        guard let targetApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            action()
            return
        }

        targetApp.activate(options: [.activateIgnoringOtherApps])
        // Brief pause to allow activation
        Thread.sleep(forTimeInterval: 0.1)

        action()

        // Restore previous app
        if let prev = previousApp {
            Thread.sleep(forTimeInterval: 0.05)
            prev.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
