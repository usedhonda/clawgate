import AppKit
import Foundation

final class LINEAdapter: AdapterProtocol {
    let name = "line"
    let bundleIdentifier = "jp.naver.line.mac"

    private let logger: AppLogger
    private let retry = RetryPolicy(maxAttempts: 2, initialDelayMs: 120)
    private let recentSendTracker: RecentSendTracker

    init(logger: AppLogger, recentSendTracker: RecentSendTracker) {
        self.logger = logger
        self.recentSendTracker = recentSendTracker
    }

    func sendMessage(payload: SendPayload) throws -> (SendResult, [StepLog]) {
        let stepLogger = StepLogger()

        try step("ensure_accessibility", logger: stepLogger) {
            guard AXIsProcessTrusted() else {
                throw BridgeRuntimeError(
                    code: "ax_permission_missing",
                    message: "Accessibility permission is not granted",
                    retriable: false,
                    failedStep: "ensure_accessibility",
                    details: "System Settings > Privacy & Security > Accessibility"
                )
            }
        }

        let app: NSRunningApplication = try step("ensure_line_running", logger: stepLogger) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac").first {
                return running
            }
            let launched = NSWorkspace.shared.launchApplication(
                withBundleIdentifier: "jp.naver.line.mac",
                options: [.default],
                additionalEventParamDescriptor: nil,
                launchIdentifier: nil
            )
            guard launched else {
                throw BridgeRuntimeError(
                    code: "line_not_running",
                    message: "Failed to launch LINE",
                    retriable: true,
                    failedStep: "ensure_line_running",
                    details: "bundleIdentifier=jp.naver.line.mac"
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
            guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac").first else {
                throw BridgeRuntimeError(
                    code: "line_not_running",
                    message: "Could not confirm LINE is running",
                    retriable: true,
                    failedStep: "ensure_line_running",
                    details: "bundleIdentifier=jp.naver.line.mac"
                )
            }
            return runningApp
        }

        let pid = app.processIdentifier
        let appElement = AXQuery.applicationElement(pid: pid)

        // Stage 1: Surface — bring LINE window to front
        let rootWindow: AXUIElement = try step("surface_line", logger: stepLogger) {
            guard let window = AXActions.ensureWindow(
                app: app, appElement: appElement, bundleID: bundleIdentifier
            ) else {
                throw BridgeRuntimeError(
                    code: "line_window_missing",
                    message: "LINE focused window not found",
                    retriable: true,
                    failedStep: "surface_line",
                    details: "hasWSWindows=\(AXActions.hasWindowServerWindows(pid: pid))"
                )
            }
            return window
        }

        let windowFrame: CGRect = try step("get_window_frame", logger: stepLogger) {
            guard let frame = AXQuery.copyFrameAttribute(rootWindow) else {
                throw BridgeRuntimeError(
                    code: "window_frame_missing",
                    message: "Could not retrieve window frame",
                    retriable: true,
                    failedStep: "get_window_frame",
                    details: nil
                )
            }
            return frame
        }

        var nodes = try step("scan_ui_tree", logger: stepLogger) {
            AXQuery.descendants(of: rootWindow)
        }

        // Stage 2: Search -> click result row to navigate to matching conversation
        _ = try step("open_conversation", logger: stepLogger) {
            let candidate = SelectorResolver.resolve(
                selector: LineSelectors.searchFieldU, in: nodes, windowFrame: windowFrame
            ) ?? legacyResolve(LineSelectors.searchField, in: nodes)

            guard let searchField = candidate else {
                throw BridgeRuntimeError(
                    code: "search_field_not_found",
                    message: "Search field not found",
                    retriable: true,
                    failedStep: "open_conversation",
                    details: "selectors=LineSelectors.searchFieldU"
                )
            }

            // 1. Activate LINE
            let activateDone = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                app.activate(options: [.activateIgnoringOtherApps])
                activateDone.signal()
            }
            activateDone.wait()
            usleep(150_000)

            // 2. Focus search field
            AXActions.setFocused(searchField.node.element)
            usleep(100_000)

            // 3. Set search text via AX API (not pasteText)
            guard AXActions.setValue(payload.conversationHint, on: searchField.node.element) else {
                throw BridgeRuntimeError(
                    code: "search_set_failed",
                    message: "Failed to set search field value",
                    retriable: true,
                    failedStep: "open_conversation",
                    details: nil
                )
            }

            // 4. Verify value was set
            let verified = AXActions.poll(intervalMs: 30, timeoutMs: 500) {
                let val = AXQuery.copyStringAttribute(
                    searchField.node.element, attribute: kAXValueAttribute as String
                ) ?? ""
                return !val.isEmpty
            }
            guard verified else {
                throw BridgeRuntimeError(
                    code: "search_value_empty",
                    message: "Search field value empty after setValue",
                    retriable: true,
                    failedStep: "open_conversation",
                    details: nil
                )
            }

            // 5. HID Enter to confirm search (triggers Qt search execution)
            // setValue alone doesn't fire Qt's textEdited signal, so search doesn't run.
            // HID Enter confirms the search query and populates result rows.
            AXActions.sendSearchEnter()
            usleep(800_000) // 800ms for search results to populate after Enter

            // 6. Click first conversation result row (height > 40, skip header rows ~34px)
            let freshNodes = AXQuery.descendants(of: rootWindow)
            let resultRow = freshNodes.first { node in
                node.role == "AXRow"
                    && (node.frame?.height ?? 0) > 40
                    && (node.frame?.width ?? 0) > 0
            }
            if let row = resultRow {
                AXActions.clickAtCenter(row.element)
            }
            // If no row found, Enter may have already navigated (v4 behavior)
            return true
        }

        // Wait for navigation: poll for messageInput to appear
        nodes = try step("rescan_after_navigation", logger: stepLogger) {
            var freshNodes: [AXNode] = []
            let found = AXActions.poll(intervalMs: 100, timeoutMs: 3000) {
                freshNodes = AXQuery.descendants(of: rootWindow)
                let windowFrameNow = AXQuery.copyFrameAttribute(rootWindow) ?? windowFrame
                let match = SelectorResolver.resolve(
                    selector: LineSelectors.messageInputU, in: freshNodes, windowFrame: windowFrameNow
                ) ?? self.legacyResolve(LineSelectors.messageInput, in: freshNodes)
                return match != nil
            }
            if found {
                return freshNodes
            }
            throw BridgeRuntimeError(
                code: "rescan_timeout",
                message: "Could not detect navigation to conversation",
                retriable: true,
                failedStep: "rescan_after_navigation",
                details: "messageInput not found after 3s polling"
            )
        }

        // Stage 2+3: Focus input -> setValue -> verify
        _ = try step("input_message", logger: stepLogger) {
            let windowFrameNow = AXQuery.copyFrameAttribute(rootWindow) ?? windowFrame
            let candidate = SelectorResolver.resolve(
                selector: LineSelectors.messageInputU, in: nodes, windowFrame: windowFrameNow
            ) ?? legacyResolve(LineSelectors.messageInput, in: nodes)

            guard let input = candidate else {
                throw BridgeRuntimeError(
                    code: "message_input_not_found",
                    message: "Message input field not found",
                    retriable: true,
                    failedStep: "input_message",
                    details: "selectors=LineSelectors.messageInputU"
                )
            }

            // Focus via setFocused (no AXPress — it has side effects on Qt)
            AXActions.setFocused(input.node.element)

            guard AXActions.setValue(payload.text, on: input.node.element) else {
                throw BridgeRuntimeError(
                    code: "message_set_failed",
                    message: "Failed to set message text",
                    retriable: true,
                    failedStep: "input_message",
                    details: nil
                )
            }

            // Poll to verify value was set
            _ = AXActions.poll(intervalMs: 20, timeoutMs: 200) {
                let currentValue = AXQuery.copyStringAttribute(input.node.element, attribute: kAXValueAttribute as String)
                return currentValue == payload.text
            }
            return true
        }

        // Stage 4: Send via AXPostKeyboardEvent Enter (LINE has no send button)
        // NOTE: Do NOT try sendButtonU here — LINE has no send button in AX tree,
        // and the selector matches close/minimize buttons (AXButton + AXPress),
        // which closes the window.
        _ = try step("send_message", logger: stepLogger) {
            let windowFrameNow = AXQuery.copyFrameAttribute(rootWindow) ?? windowFrame

            let inputCandidate = SelectorResolver.resolve(
                selector: LineSelectors.messageInputU, in: nodes, windowFrame: windowFrameNow
            ) ?? legacyResolve(LineSelectors.messageInput, in: nodes)
            if let input = inputCandidate {
                AXActions.setFocused(input.node.element)
                usleep(50_000)
            }
            AXActions.sendEnter(pid: pid)
            return true
        }

        logger.log(.info, "LINE send flow finished for \(payload.conversationHint)")
        recentSendTracker.recordSend(conversation: payload.conversationHint, text: payload.text)

        let result = SendResult(
            adapter: name,
            action: "send_message",
            messageID: "local-\(UUID().uuidString)",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        return (result, stepLogger.all())
    }

    // MARK: - Read API

    func getContext() throws -> ConversationContext {
        try withLINEWindow { rootWindow, windowFrame, nodes in
            let windowTitle = AXQuery.copyStringAttribute(rootWindow, attribute: kAXTitleAttribute as String)
            let hasInput = SelectorResolver.resolve(
                selector: LineSelectors.messageInputU, in: nodes, windowFrame: windowFrame
            ) != nil
            return ConversationContext(
                adapter: name,
                conversationName: windowTitle,
                hasInputField: hasInput,
                windowTitle: windowTitle,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
        }
    }

    func getMessages(limit: Int) throws -> MessageList {
        try withLINEWindow { rootWindow, windowFrame, nodes in
            let windowTitle = AXQuery.copyStringAttribute(rootWindow, attribute: kAXTitleAttribute as String)

            let messageAreaLeft = windowFrame.origin.x + windowFrame.width * 0.2
            let messageAreaWidth = windowFrame.width * 0.8

            let textNodes = nodes.filter { node in
                guard node.role == "AXStaticText", let frame = node.frame else { return false }
                let relX = Double(frame.midX - windowFrame.origin.x) / Double(windowFrame.width)
                let relY = Double(frame.midY - windowFrame.origin.y) / Double(windowFrame.height)
                let geo = LineSelectors.messageTextU.geometryHint!
                return geo.regionX.contains(relX) && geo.regionY.contains(relY)
            }

            let visibleTexts: [(text: String, frame: CGRect)] = textNodes.compactMap { node in
                let text = node.value ?? node.title ?? node.description
                guard let t = text, !t.isEmpty, let frame = node.frame else { return nil }
                guard !LINEAdapter.isUIChrome(t, windowTitle: windowTitle) else { return nil }
                return (text: t, frame: frame)
            }

            let sorted = visibleTexts.sorted { $0.frame.origin.y < $1.frame.origin.y }
            let limited = Array(sorted.suffix(limit))

            let messages = limited.enumerated().map { (index, item) -> VisibleMessage in
                let relativeX = messageAreaWidth > 0
                    ? Double(item.frame.midX - messageAreaLeft) / Double(messageAreaWidth)
                    : 0.5
                let sender: String
                if relativeX < 0.45 {
                    sender = "other"
                } else if relativeX > 0.55 {
                    sender = "self"
                } else {
                    sender = "unknown"
                }
                return VisibleMessage(text: item.text, sender: sender, yOrder: index)
            }

            return MessageList(
                adapter: name,
                conversationName: windowTitle,
                messages: messages,
                messageCount: messages.count,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
        }
    }

    func getConversations(limit: Int) throws -> ConversationList {
        try withLINEWindow { rootWindow, windowFrame, nodes in
            let sidebarNodes = nodes.filter { node in
                guard node.role == "AXStaticText", let frame = node.frame else { return false }
                let relX = Double(frame.midX - windowFrame.origin.x) / Double(windowFrame.width)
                let relY = Double(frame.midY - windowFrame.origin.y) / Double(windowFrame.height)
                let geo = LineSelectors.conversationNameU.geometryHint!
                return geo.regionX.contains(relX) && geo.regionY.contains(relY)
            }

            guard !sidebarNodes.isEmpty else {
                throw BridgeRuntimeError(
                    code: "sidebar_not_visible",
                    message: "Sidebar is not visible",
                    retriable: true,
                    failedStep: "get_conversations",
                    details: nil
                )
            }

            let windowTitle = AXQuery.copyStringAttribute(rootWindow, attribute: kAXTitleAttribute as String)

            struct SidebarItem {
                let text: String
                let frame: CGRect
            }

            let items: [SidebarItem] = sidebarNodes.compactMap { node in
                let text = node.value ?? node.title ?? node.description
                guard let t = text, !t.isEmpty, let frame = node.frame else { return nil }
                guard !LINEAdapter.isUIChrome(t, windowTitle: windowTitle) else { return nil }
                return SidebarItem(text: t, frame: frame)
            }.sorted { $0.frame.origin.y < $1.frame.origin.y }

            // Group by Y proximity (< 10px = same conversation)
            var groups: [[SidebarItem]] = []
            for item in items {
                if let lastGroup = groups.last, let lastItem = lastGroup.last,
                   abs(item.frame.origin.y - lastItem.frame.origin.y) < 10 {
                    groups[groups.count - 1].append(item)
                } else {
                    groups.append([item])
                }
            }

            // Detect unread: a digit-only text node to the right of the conversation name
            let digitNodes = sidebarNodes.filter { node in
                let text = node.value ?? node.title ?? node.description
                guard let t = text, !t.isEmpty else { return false }
                return t.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy(\.isNumber)
            }

            let conversations: [ConversationEntry] = groups.prefix(limit).enumerated().map { index, group in
                let convName = group.max(by: { $0.text.count < $1.text.count })?.text ?? ""
                let mainFrame = group.first?.frame
                let hasUnread = mainFrame.map { mf in
                    digitNodes.contains { digit in
                        guard let df = digit.frame else { return false }
                        return df.origin.x > mf.origin.x && abs(df.midY - mf.midY) < 15
                    }
                } ?? false
                return ConversationEntry(name: convName, yOrder: index, hasUnread: hasUnread)
            }

            return ConversationList(
                adapter: name,
                conversations: conversations,
                count: conversations.count,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
        }
    }

    // MARK: - UI Chrome Filter

    private static let timestampPattern: NSRegularExpression = {
        // Matches patterns like "12:34", "2026/2/6", weekday names, "AM/PM" etc.
        try! NSRegularExpression(
            pattern: #"^(\d{1,2}:\d{2}(:\d{2})?|(\d{2,4}[/\-]\d{1,2}[/\-]\d{1,2})|(月|火|水|木|金|土|日)曜日?|[AP]M|yesterday|today|今日|昨日)$"#,
            options: [.caseInsensitive]
        )
    }()

    static func isUIChrome(_ text: String, windowTitle: String?) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 1 { return true }
        if t == windowTitle { return true }
        if t.allSatisfy(\.isNumber) { return true }
        let range = NSRange(t.startIndex..., in: t)
        return timestampPattern.firstMatch(in: t, range: range) != nil
    }

    // MARK: - Common helper for read-only operations

    private func withLINEWindow<T>(
        body: (_ rootWindow: AXUIElement, _ windowFrame: CGRect, _ nodes: [AXNode]) throws -> T
    ) throws -> T {
        do {
            return try AXAppWindow.withWindow(bundleIdentifier: bundleIdentifier) { ctx in
                try body(ctx.window, ctx.frame, ctx.nodes)
            }
        } catch AXAppWindow.WindowError.axPermissionMissing {
            throw BridgeRuntimeError(
                code: "ax_permission_missing",
                message: "Accessibility permission is not granted",
                retriable: false,
                failedStep: "ensure_accessibility",
                details: "System Settings > Privacy & Security > Accessibility"
            )
        } catch AXAppWindow.WindowError.appNotRunning {
            throw BridgeRuntimeError(
                code: "line_not_running",
                message: "LINE is not running",
                retriable: true,
                failedStep: "ensure_line_running",
                details: "bundleIdentifier=\(bundleIdentifier)"
            )
        } catch AXAppWindow.WindowError.windowNotFound {
            throw BridgeRuntimeError(
                code: "line_window_missing",
                message: "LINE focused window not found",
                retriable: true,
                failedStep: "find_main_window",
                details: nil
            )
        } catch AXAppWindow.WindowError.frameNotFound {
            throw BridgeRuntimeError(
                code: "window_frame_missing",
                message: "Could not retrieve window frame",
                retriable: true,
                failedStep: "get_window_frame",
                details: nil
            )
        }
    }

    private func legacyResolve(_ selector: LineSelector, in nodes: [AXNode]) -> SelectorCandidate? {
        guard let node = AXQuery.bestMatch(selector: selector, in: nodes) else { return nil }
        return SelectorCandidate(node: node, confidence: 0.3, matchedLayer: 1)
    }

    private func step<T>(
        _ name: String,
        logger: StepLogger,
        block: () throws -> T
    ) throws -> T {
        let started = Date()
        do {
            let value = try retry.run(block)
            logger.record(step: name, start: started, success: true, details: "ok")
            return value
        } catch {
            logger.record(step: name, start: started, success: false, details: String(describing: error))
            throw error
        }
    }
}
