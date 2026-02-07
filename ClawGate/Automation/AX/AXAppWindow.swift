import AppKit
import ApplicationServices
import Foundation

/// Generic helper for accessing an application's focused window via AX API.
/// Extracts common logic: AX permission check -> app lookup -> activate -> window -> frame -> descendants
enum AXAppWindow {
    /// Context passed to the body closure with window information.
    struct WindowContext {
        let window: AXUIElement
        let frame: CGRect
        let nodes: [AXNode]
    }

    /// Errors that can occur when accessing an application window.
    enum WindowError: Error {
        case axPermissionMissing
        case appNotRunning(bundleIdentifier: String)
        case windowNotFound(bundleIdentifier: String)
        case frameNotFound
    }

    /// Executes a closure with the focused window of an application.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The bundle identifier of the target application
    ///   - activate: Whether to activate the app before accessing its window (default: true)
    ///   - maxDepth: Maximum depth for AX tree traversal (default: 6)
    ///   - maxNodes: Maximum number of nodes to collect (default: 500)
    ///   - body: Closure that receives the WindowContext and returns a value
    /// - Returns: The value returned by the body closure
    /// - Throws: WindowError or any error thrown by the body closure
    static func withWindow<T>(
        bundleIdentifier: String,
        activate: Bool = true,
        maxDepth: Int = 6,
        maxNodes: Int = 500,
        body: (WindowContext) throws -> T
    ) throws -> T {
        guard AXIsProcessTrusted() else {
            throw WindowError.axPermissionMissing
        }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw WindowError.appNotRunning(bundleIdentifier: bundleIdentifier)
        }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)

        if activate {
            guard AXActions.ensureWindow(
                app: app, appElement: appElement, bundleID: bundleIdentifier
            ) != nil else {
                throw WindowError.windowNotFound(bundleIdentifier: bundleIdentifier)
            }
        }

        guard let window = AXQuery.focusedWindow(appElement: appElement) else {
            throw WindowError.windowNotFound(bundleIdentifier: bundleIdentifier)
        }

        guard let frame = AXQuery.copyFrameAttribute(window) else {
            throw WindowError.frameNotFound
        }

        let nodes = AXQuery.descendants(of: window, maxDepth: maxDepth, maxNodes: maxNodes)
        let context = WindowContext(window: window, frame: frame, nodes: nodes)

        return try body(context)
    }
}
