import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum AXActions {
    static func setValue(_ text: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    @discardableResult
    static func setFocused(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    // AXUIElementPostKeyboardEvent is deprecated (10.9) and unavailable in Swift.
    // Load it dynamically via dlsym to bypass the Swift availability gate.
    private typealias AXPostKeyboardEventFn = @convention(c) (
        AXUIElement, CGCharCode, CGKeyCode, Bool
    ) -> AXError

    private static let axPostKeyboardEvent: AXPostKeyboardEventFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "AXUIElementPostKeyboardEvent") else {
            return nil
        }
        return unsafeBitCast(sym, to: AXPostKeyboardEventFn.self)
    }()

    /// Send Enter via AXUIElementPostKeyboardEvent (direct to PID, bypasses WindowServer/TSM).
    /// CGEvent strategies removed — they interfere with Qt window focus.
    static func sendEnter(pid: pid_t) {
        guard let post = axPostKeyboardEvent else {
            NSLog("[AXActions] sendEnter SKIP: dlsym returned nil")
            return
        }
        let app = AXUIElementCreateApplication(pid)
        let downResult = post(app, 0, 36, true)
        usleep(20_000)
        let upResult = post(app, 0, 36, false)
        NSLog("[AXActions] sendEnter AXPost pid=%d down=%d up=%d",
              pid, downResult.rawValue, upResult.rawValue)
    }

    /// Send Enter straight to one process with a supported API.
    ///
    /// `AXUIElementPostKeyboardEvent` has been deprecated since 10.9 and on
    /// macOS 27 it no longer delivers: the text still lands in LINE's input
    /// box, but the message is never sent and the call reports nothing wrong
    /// (observed 2026-09-24 on an M6 running 27.0/26A425; the same build sent
    /// fine on the Intel machine running 26). `CGEvent.postToPid` keeps the
    /// property the old call was chosen for — delivery to one process, not
    /// through the HID tap, which disturbs Qt's window focus — while being an
    /// API that is still supported.
    static func sendEnterToPid(_ pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            NSLog("[AXActions] sendEnterToPid: no CGEventSource")
            return
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        down?.postToPid(pid)
        usleep(20_000)
        up?.postToPid(pid)
        NSLog("[AXActions] sendEnterToPid pid=%d posted", pid)
    }

    /// Send Escape via CGEvent at HID level to dismiss search mode.
    static func sendEscape() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            NSLog("[AXActions] sendEscape: no CGEventSource")
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        NSLog("[AXActions] sendEscape: HID Escape posted")
    }

    /// Send Enter via CGEvent at HID level for search field navigation.
    /// This is specifically for LINE's search: setValue + HID Enter navigates to the first
    /// matching conversation. Unlike sendEnter(pid:) which uses AXPostKeyboardEvent (PID-targeted),
    /// this posts at the HID layer which Qt's search field reliably receives.
    /// NOTE: Do NOT use this for message sending — HID Enter doesn't reach Qt's message input.
    static func sendSearchEnter() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            NSLog("[AXActions] sendSearchEnter: no CGEventSource")
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        NSLog("[AXActions] sendSearchEnter: HID Enter posted")
    }

    /// Paste text into the focused field via clipboard (Cmd+A, Cmd+V).
    /// This triggers Qt's "user edit" path (textEdited signal) unlike AX setValue
    /// which only triggers the programmatic textChanged path.
    static func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = captureClipboardItems(from: pasteboard)

        let ownedChangeCount = writeTemporaryClipboard(text, to: pasteboard)

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            NSLog("[AXActions] pasteText: no CGEventSource")
            _ = restoreClipboardIfUnchanged(
                pasteboard: pasteboard,
                savedItems: savedItems,
                expectedChangeCount: ownedChangeCount
            )
            return
        }

        // Cmd+A (select all) - keyCode 0 = 'a'
        let aDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let aUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        aDown?.flags = .maskCommand
        aUp?.flags = .maskCommand
        aDown?.post(tap: .cghidEventTap)
        aUp?.post(tap: .cghidEventTap)
        usleep(50_000)

        // Cmd+V (paste) - keyCode 9 = 'v'
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        NSLog("[AXActions] pasteText: pasted %d chars via Cmd+V", text.count)

        // Restore clipboard after a short delay
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            _ = restoreClipboardIfUnchanged(
                pasteboard: pasteboard,
                savedItems: savedItems,
                expectedChangeCount: ownedChangeCount
            )
        }
    }

    /// Paste text via clipboard using Cmd+V only (no Cmd+A).
    /// Safer than `pasteText` — does not select-all, so won't overwrite content
    /// in a wrongly-focused field. Preserves full clipboard (images, files, RTF).
    static func safePaste(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save ALL clipboard items (not just string — preserve images, files, RTF etc.)
        let savedItems = captureClipboardItems(from: pasteboard)

        let ownedChangeCount = writeTemporaryClipboard(text, to: pasteboard)

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            NSLog("[AXActions] safePaste: no CGEventSource, restoring clipboard")
            _ = restoreClipboardIfUnchanged(
                pasteboard: pasteboard,
                savedItems: savedItems,
                expectedChangeCount: ownedChangeCount
            )
            return
        }

        // Cmd+V only (no Cmd+A — avoids select-all in wrong field)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        NSLog("[AXActions] safePaste: pasted %d chars via Cmd+V (no Cmd+A)", text.count)

        // Restore clipboard after a short delay
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            _ = restoreClipboardIfUnchanged(
                pasteboard: pasteboard,
                savedItems: savedItems,
                expectedChangeCount: ownedChangeCount
            )
        }
    }

    private static func captureClipboardItems(
        from pasteboard: NSPasteboard
    ) -> [[NSPasteboard.PasteboardType: Data]]? {
        pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
    }

    private static func writeTemporaryClipboard(
        _ text: String,
        to pasteboard: NSPasteboard
    ) -> Int {
        ClipboardWatcher.shared.writeOwnedString(text, to: pasteboard)
    }

    @discardableResult
    private static func restoreClipboardIfUnchanged(
        pasteboard: NSPasteboard,
        savedItems: [[NSPasteboard.PasteboardType: Data]]?,
        expectedChangeCount: Int
    ) -> Bool {
        ClipboardWatcher.shared.performOwnedMutationIfCurrentChangeCount(
            expectedChangeCount,
            on: pasteboard
        ) {
            restoreClipboardContents(pasteboard: pasteboard, savedItems: savedItems)
        } != nil
    }

    /// Restore clipboard from saved items (all types, all items in one call).
    private static func restoreClipboardContents(
        pasteboard: NSPasteboard,
        savedItems: [[NSPasteboard.PasteboardType: Data]]?
    ) {
        pasteboard.clearContents()
        guard let saved = savedItems, !saved.isEmpty else { return }
        let restoredItems: [NSPasteboardItem] = saved.map { itemDict in
            let newItem = NSPasteboardItem()
            for (type, data) in itemDict {
                newItem.setData(data, forType: type)
            }
            return newItem
        }
        pasteboard.writeObjects(restoredItems)
    }

    #if DEBUG
    static func writeTemporaryClipboardForTesting(
        _ text: String,
        pasteboard: NSPasteboard
    ) -> Int {
        writeTemporaryClipboard(text, to: pasteboard)
    }

    static func restoreClipboardIfUnchangedForTesting(
        savedText: String?,
        expectedChangeCount: Int,
        pasteboard: NSPasteboard
    ) -> Bool {
        let savedItems: [[NSPasteboard.PasteboardType: Data]]? = savedText.map { text in
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            if let data = item.data(forType: .string) {
                values[.string] = data
            }
            return [values]
        }
        return restoreClipboardIfUnchanged(
            pasteboard: pasteboard,
            savedItems: savedItems,
            expectedChangeCount: expectedChangeCount
        )
    }
    #endif

    // MARK: - Window discovery

    /// Find the CGWindowID for a PID's main window (layer 0, on-screen).
    /// Used for single-window capture (CGWindowListCreateImage with .optionIncludingWindow).
    static func findWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            return number
        }
        return nil
    }

    /// Check if a PID has any windows at the WindowServer level (including off-screen).
    static func hasWindowServerWindows(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return ownerPID == pid
        }
    }

    /// Send kAEReopenApplication Apple Event to trigger window creation (Dock-click equivalent).
    /// Must be called from Main Thread for reliability.
    static func sendReopenEvent(bundleID: String) {
        guard let bundleData = bundleID.data(using: .utf8) else { return }
        let target = NSAppleEventDescriptor(
            descriptorType: typeApplicationBundleID,
            data: bundleData
        )
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        // Use a throwaway AppleScript as alternative if direct send fails
        do {
            _ = try event.sendEvent(
                options: NSAppleEventDescriptor.SendOptions(rawValue: 0x00000003), // kAEWaitReply
                timeout: 2.0
            )
            NSLog("[AXActions] sendReopenEvent: sent to %@", bundleID)
        } catch {
            NSLog("[AXActions] sendReopenEvent: Apple Event failed (%@), trying osascript", "\(error)")
            // Fallback: osascript
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application id \"\(bundleID)\" to activate"]
            try? task.run()
            task.waitUntilExit()
        }
    }

    /// Bring an app's window to existence and foreground. Handles the "0 windows" case.
    /// Tries: AX surface -> kAEReopenApplication -> activate on main thread.
    static func ensureWindow(
        app: NSRunningApplication,
        appElement: AXUIElement,
        bundleID: String
    ) -> AXUIElement? {
        let pid = app.processIdentifier

        // 0. Unhide if hidden
        let isHidden = AXQuery.copyBoolAttribute(appElement, attribute: kAXHiddenAttribute as String) ?? false
        if isHidden {
            AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, kCFBooleanFalse)
            NSLog("[AXActions] ensureWindow: unhiding app")
            usleep(300_000)
        }

        // 1. Already have a focused window?
        if let w = AXQuery.focusedWindow(appElement: appElement) {
            surface(app: appElement, window: w)
            return w
        }

        // 2. Have any window (maybe minimized)?
        if let w = AXQuery.windows(appElement: appElement).first {
            NSLog("[AXActions] ensureWindow: surfacing existing window")
            surface(app: appElement, window: w)
            var focused: AXUIElement?
            _ = poll(intervalMs: 50, timeoutMs: 1000) {
                focused = AXQuery.focusedWindow(appElement: appElement)
                return focused != nil
            }
            return focused ?? w
        }

        // 3. No windows — send kAEReopenApplication from Main Thread
        NSLog("[AXActions] ensureWindow: no windows, sending reopen event")
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            sendReopenEvent(bundleID: bundleID)
            semaphore.signal()
        }
        semaphore.wait()

        // Poll for window to appear
        var foundWindow: AXUIElement?
        let ok1 = poll(intervalMs: 100, timeoutMs: 3000) {
            if let w = AXQuery.focusedWindow(appElement: appElement) {
                foundWindow = w
                return true
            }
            if let w = AXQuery.windows(appElement: appElement).first {
                foundWindow = w
                return true
            }
            return false
        }
        if ok1, let w = foundWindow {
            NSLog("[AXActions] ensureWindow: window appeared after reopen event")
            surface(app: appElement, window: w)
            return w
        }

        // 4. Reopen didn't work — activate on Main Thread as last resort
        NSLog("[AXActions] ensureWindow: reopen failed, trying activate on main thread")
        let sem2 = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            sem2.signal()
        }
        sem2.wait()

        let ok2 = poll(intervalMs: 100, timeoutMs: 3000) {
            if let w = AXQuery.focusedWindow(appElement: appElement) {
                foundWindow = w
                return true
            }
            if let w = AXQuery.windows(appElement: appElement).first {
                foundWindow = w
                return true
            }
            return false
        }
        if ok2, let w = foundWindow {
            NSLog("[AXActions] ensureWindow: window appeared after activate")
            surface(app: appElement, window: w)
            return w
        }

        NSLog("[AXActions] ensureWindow: all attempts failed, hasWSWindows=%d",
              hasWindowServerWindows(pid: pid) ? 1 : 0)
        return nil
    }

    // MARK: - Window geometry

    /// Set the position of a window (kAXPositionAttribute).
    @discardableResult
    static func setWindowPosition(_ window: AXUIElement, to point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    /// Set the size of a window (kAXSizeAttribute).
    @discardableResult
    static func setWindowSize(_ window: AXUIElement, to size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    /// Set window to the given frame and verify. Returns the actual frame after setting.
    @discardableResult
    static func setWindowFrame(_ window: AXUIElement, to frame: CGRect) -> CGRect? {
        setWindowPosition(window, to: frame.origin)
        usleep(50_000)
        setWindowSize(window, to: frame.size)
        usleep(100_000)

        // Verify
        guard let actual = AXQuery.copyFrameAttribute(window) else { return nil }
        NSLog("[AXActions] setWindowFrame: requested=(%.0f,%.0f %.0fx%.0f) actual=(%.0f,%.0f %.0fx%.0f)",
              frame.origin.x, frame.origin.y, frame.width, frame.height,
              actual.origin.x, actual.origin.y, actual.width, actual.height)
        return actual
    }

    /// LINE's sidebar is a fixed-width Qt pane, so narrowing the window raises
    /// its share of the width rather than shrinking it. Measured at 302px
    /// against a 1200x859 window (the fixture in `LineSidebarDiscoveryTests`).
    static let lineSidebarWidth: CGFloat = 302

    /// `LineSidebarDiscovery` refuses a sidebar wider than 0.35 of the window,
    /// and that refusal is not a degraded selector — `resolveLineMainWindow`
    /// finds no window at all, which takes the whole read path down with it.
    /// Staying at 0.32 leaves room for LINE to differ from the measurement.
    static let lineSidebarMaxWidthShare: CGFloat = 0.32

    /// The narrowest the window may be placed before sidebar discovery is at
    /// risk. About 944px.
    static var minimumLineWindowWidth: CGFloat { lineSidebarWidth / lineSidebarMaxWidthShare }

    /// Where the LINE window should sit: top-left corner, half the width, the
    /// full usable height. Left half so the rest of the screen stays usable —
    /// it used to take 1200x900 out of the middle-left of a 1920x1080 desktop.
    ///
    /// Pure, so the arithmetic can be tested without a display attached.
    /// - Parameters:
    ///   - visibleFrame: AppKit's usable area (menu bar and Dock already out),
    ///     bottom-left origin.
    ///   - desktopMaxY: the top edge of the whole desktop in AppKit
    ///     coordinates, for the flip to AX's top-left origin.
    static func lineWindowFrame(visibleFrame: CGRect,
                                desktopMaxY: CGFloat,
                                widthRatio: CGFloat = 0.5) -> CGRect {
        // The floor never exceeds what the display actually has.
        let floor = min(minimumLineWindowWidth, visibleFrame.width)
        let width = max(visibleFrame.width * widthRatio, floor)
        return CGRect(x: visibleFrame.minX,
                      y: desktopMaxY - visibleFrame.maxY,
                      width: width,
                      height: visibleFrame.height)
    }

    /// Place the window only when it is not already where it belongs.
    ///
    /// The inbound poller runs this on every tick, so writing position and size
    /// unconditionally would mean two AX writes a second against LINE for no
    /// reason. `tolerance` absorbs the pixel or two that LINE gives back.
    /// Returns true when it actually moved something.
    @discardableResult
    static func placeWindowIfNeeded(_ window: AXUIElement,
                                    to frame: CGRect,
                                    tolerance: CGFloat = 4) -> Bool {
        if let current = AXQuery.copyFrameAttribute(window),
           abs(current.minX - frame.minX) <= tolerance,
           abs(current.minY - frame.minY) <= tolerance,
           abs(current.width - frame.width) <= tolerance,
           abs(current.height - frame.height) <= tolerance {
            return false
        }
        _ = setWindowFrame(window, to: frame)
        return true
    }

    /// `lineWindowFrame` against the live screen.
    static func optimalWindowFrame() -> CGRect {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1055)
        // Flipped against the whole desktop, not `screens.first`: the main
        // screen and the primary screen are not always the same one, and using
        // the wrong height puts the window off-screen. Same rule the Pet window
        // uses (`PetModel.desktopMaxY`).
        let desktopMaxY = NSScreen.screens.map(\.frame.maxY).max()
            ?? (NSScreen.main?.frame.maxY ?? visible.maxY)
        return lineWindowFrame(visibleFrame: visible, desktopMaxY: desktopMaxY)
    }

    // MARK: - 4-Stage Pipeline helpers

    /// Generic polling: checks condition every intervalMs until it returns true or timeoutMs elapses.
    static func poll(intervalMs: UInt32 = 15, timeoutMs: UInt32 = 500, condition: () -> Bool) -> Bool {
        let start = DispatchTime.now()
        let timeoutNs = UInt64(timeoutMs) * 1_000_000
        while true {
            if condition() { return true }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            if elapsed >= timeoutNs { return false }
            usleep(intervalMs * 1000)
        }
    }

    /// Stage 1: Bring window to front without NSRunningApplication.activate().
    /// Uses AX attributes to avoid LINE's toggle-minimize behavior.
    @discardableResult
    static func surface(app: AXUIElement, window: AXUIElement) -> Bool {
        // 0. Unhide app if hidden (hidden apps have no visible windows)
        let isHidden = AXQuery.copyBoolAttribute(app, attribute: kAXHiddenAttribute as String) ?? false
        if isHidden {
            AXUIElementSetAttributeValue(app, kAXHiddenAttribute as CFString, kCFBooleanFalse)
            NSLog("[AXActions] surface: unhiding app")
        }

        // 1. Un-minimize if minimized
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)

        // 2. Set app as frontmost
        let directFrontResult = AXUIElementSetAttributeValue(
            app, kAXFrontmostAttribute as CFString, kCFBooleanTrue
        )

        // 3. Raise the window
        let directRaiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)

        // 4. Poll to confirm: frontmost == true AND minimized == false
        let success = poll(intervalMs: 15, timeoutMs: 500) {
            let isFront = AXQuery.copyBoolAttribute(app, attribute: kAXFrontmostAttribute as String) ?? false
            let isMinimized = AXQuery.copyBoolAttribute(window, attribute: kAXMinimizedAttribute as String) ?? true
            return isFront && !isMinimized
        }

        let directSucceeded = directFrontResult == .success
            && directRaiseResult == .success
            && success
        if directSucceeded {
            NSLog("[AXActions] surface OK")
            return true
        }

        // Fallback: activate with empty options (no toggle behavior)
        NSLog("[AXActions] surface: AX attributes insufficient, fallback to activate(options:[])")
        guard let pid = AXQuery.pid(of: app),
              let runningApp = NSRunningApplication(processIdentifier: pid),
              runningApp.activate(options: []) else {
            return false
        }
        return poll(intervalMs: 15, timeoutMs: 500) {
            let isFront = AXQuery.copyBoolAttribute(app, attribute: kAXFrontmostAttribute as String) ?? false
            let isMinimized = AXQuery.copyBoolAttribute(window, attribute: kAXMinimizedAttribute as String) ?? true
            return isFront && !isMinimized
        }
    }

    #if DEBUG
    static func surfaceResultForTesting(directSucceeded: Bool, fallbackSucceeded: Bool) -> Bool {
        directSucceeded || fallbackSucceeded
    }
    #endif

    /// Click at the center of an AXUIElement using CGEvent mouse events.
    /// Used for Qt elements that lack AXPress action (e.g. LINE search result rows).
    /// When restoreCursor is true, saves and restores the mouse position to avoid
    /// visible cursor movement.
    static func clickAtCenter(_ element: AXUIElement, restoreCursor: Bool = false) -> Bool {
        guard let frame = AXQuery.copyFrameAttribute(element) else {
            NSLog("[AXActions] clickAtCenter: no frame")
            return false
        }
        guard frame.width > 0 && frame.height > 0 else {
            NSLog("[AXActions] clickAtCenter: zero-size frame")
            return false
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let savedPos = restoreCursor ? CGEvent(source: nil)?.location : nil

        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                mouseCursorPosition: center, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
        usleep(50_000)

        let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                mouseCursorPosition: center, mouseButton: .left)
        downEvent?.post(tap: .cghidEventTap)
        usleep(50_000)

        let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                              mouseCursorPosition: center, mouseButton: .left)
        upEvent?.post(tap: .cghidEventTap)

        // Restore cursor to original position
        if let orig = savedPos {
            usleep(50_000)
            let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                       mouseCursorPosition: orig, mouseButton: .left)
            restoreEvent?.post(tap: .cghidEventTap)
        }

        NSLog("[AXActions] clickAtCenter: clicked at (%.0f, %.0f) restore=%d", center.x, center.y, restoreCursor ? 1 : 0)
        return true
    }
}
