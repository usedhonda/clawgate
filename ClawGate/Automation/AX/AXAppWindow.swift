import AppKit
import ApplicationServices
import Foundation

/// Generic helper for accessing an application's focused window via AX API.
/// Extracts common logic: AX permission check -> app lookup -> activate -> window -> frame -> descendants
enum AXAppWindow {
    struct WindowIdentity: Equatable {
        let pid: pid_t
        let bundleIdentifier: String
        let windowIdentifier: String?
        let frame: CGRect
        let title: String?

        func matches(_ other: WindowIdentity) -> Bool {
            guard pid == other.pid, bundleIdentifier == other.bundleIdentifier else {
                return false
            }
            if let windowIdentifier, let otherIdentifier = other.windowIdentifier {
                return windowIdentifier == otherIdentifier
            }
            guard windowIdentifier == nil, other.windowIdentifier == nil else { return false }
            return title == other.title
                && abs(frame.minX - other.frame.minX) < 1
                && abs(frame.minY - other.frame.minY) < 1
                && abs(frame.width - other.frame.width) < 1
                && abs(frame.height - other.frame.height) < 1
        }
    }

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
        case targetMismatch
    }

    /// Executes a closure against the exact captured process/window without
    /// activating a different instance that shares the same bundle identifier.
    static func withWindow<T>(
        target: WindowIdentity,
        maxDepth: Int = 6,
        maxNodes: Int = 500,
        body: (WindowContext) throws -> T
    ) throws -> T {
        guard AXIsProcessTrusted() else {
            throw WindowError.axPermissionMissing
        }

        guard let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == target.bundleIdentifier else {
            throw WindowError.targetMismatch
        }

        let appElement = AXQuery.applicationElement(pid: target.pid)
        guard let window = AXQuery.windows(appElement: appElement).first(where: {
            identity(for: $0, pid: target.pid, bundleIdentifier: target.bundleIdentifier)?.matches(target) == true
        }),
        let frame = AXQuery.copyFrameAttribute(window) else {
            throw WindowError.targetMismatch
        }

        let nodes = AXQuery.descendants(of: window, maxDepth: maxDepth, maxNodes: maxNodes)
        return try body(WindowContext(window: window, frame: frame, nodes: nodes))
    }

    static func isCurrentTarget(
        _ target: WindowIdentity,
        app: NSRunningApplication,
        window: AXUIElement
    ) -> Bool {
        guard app.processIdentifier == target.pid,
              app.bundleIdentifier == target.bundleIdentifier,
              app.isActive,
              let identity = identity(for: window, pid: target.pid, bundleIdentifier: target.bundleIdentifier),
              let focused = AXQuery.focusedWindow(appElement: AXQuery.applicationElement(pid: target.pid)) else {
            return false
        }
        let appElement = AXQuery.applicationElement(pid: target.pid)
        return isValidCurrentTarget(
            target: target,
            current: identity,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            focused: CFEqual(focused, window)
                && AXQuery.copyBoolAttribute(appElement, attribute: kAXFrontmostAttribute as String) == true,
            minimized: AXQuery.copyBoolAttribute(window, attribute: kAXMinimizedAttribute as String) == true
        )
    }

    /// Pure target decision shared by production revalidation and deterministic tests.
    static func isValidCurrentTarget(
        target: WindowIdentity,
        current: WindowIdentity,
        frontmostPID: pid_t?,
        focused: Bool,
        minimized: Bool
    ) -> Bool {
        target.matches(current)
            && frontmostPID == target.pid
            && focused
            && !minimized
    }

    private static func identity(
        for window: AXUIElement,
        pid: pid_t,
        bundleIdentifier: String
    ) -> WindowIdentity? {
        guard let frame = AXQuery.copyFrameAttribute(window) else { return nil }
        return WindowIdentity(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            windowIdentifier: AXQuery.copyStringAttribute(window, attribute: "AXIdentifier"),
            frame: frame,
            title: AXQuery.copyStringAttribute(window, attribute: kAXTitleAttribute as String)
        )
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
