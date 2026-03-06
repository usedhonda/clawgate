import AppKit
import Foundation

final class LINEAdapter: AdapterProtocol {
    let name = "line"
    let bundleIdentifier = "jp.naver.line.mac"

    private let logger: AppLogger
    private let retry = RetryPolicy(maxAttempts: 2, initialDelayMs: 120)
    private let recentSendTracker: RecentSendTracker
    private var lastConversationHint: String?

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

        // Resize window to optimal dimensions for OCR visibility
        _ = try step("optimize_window", logger: stepLogger) {
            let optimal = AXActions.optimalWindowFrame()
            guard let actual = AXActions.setWindowFrame(rootWindow, to: optimal) else {
                throw BridgeRuntimeError(
                    code: "window_resize_failed",
                    message: "Could not resize LINE window",
                    retriable: true,
                    failedStep: "optimize_window",
                    details: "target=\(Int(optimal.width))x\(Int(optimal.height))"
                )
            }
            // Verify dimensions are close enough (window managers may constrain)
            let widthOK = actual.width >= optimal.width * 0.8
            let heightOK = actual.height >= optimal.height * 0.8
            if !widthOK || !heightOK {
                logger.log(.warning, "Window resize constrained: requested \(Int(optimal.width))x\(Int(optimal.height)), got \(Int(actual.width))x\(Int(actual.height))")
            }
            return actual
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

        // Same-conversation cache: skip search if already in the right conversation
        var canSkipNavigation = false
        var sidebarDetectedAfterSearch = false
        var clickedSidebarResultRow = false
        if let lastHint = lastConversationHint, lastHint == payload.conversationHint {
            let wfNow = AXQuery.copyFrameAttribute(rootWindow) ?? windowFrame
            if (SelectorResolver.resolve(
                selector: LineSelectors.messageInputU, in: nodes, windowFrame: wfNow
            ) ?? legacyResolve(LineSelectors.messageInput, in: nodes)) != nil {
                canSkipNavigation = true
                stepLogger.record(step: "open_conversation", start: Date(), success: true, details: "skipped (same conversation)")
                stepLogger.record(step: "rescan_after_navigation", start: Date(), success: true, details: "skipped (same conversation)")
                logger.log(.info, "Same conversation skip: '\(payload.conversationHint)'")
            }
        }

        if !canSkipNavigation {
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
            usleep(400_000) // 400ms for search results to populate after Enter

            // 6. Click the first visible row from the sidebar result list only.
            let freshNodes = AXQuery.descendants(of: rootWindow)
            let freshWindowFrame = AXQuery.copyFrameAttribute(rootWindow) ?? windowFrame
            if let sidebar = LineSidebarDiscovery.findSidebarList(in: freshNodes, windowFrame: freshWindowFrame) {
                sidebarDetectedAfterSearch = true
                logger.log(.debug, "LINE search sidebar detected rows=\(sidebar.visibleRows.count)")
                if let row = sidebar.visibleRows.first {
                    clickedSidebarResultRow = true
                    logger.log(.info, "LINE search result click row_y=\(Int(row.frame.minY)) rows=\(sidebar.visibleRows.count)")
                    _ = AXActions.clickAtCenter(row.element)
                } else {
                    logger.log(.warning, "LINE search sidebar found but no clickable rows")
                }
            } else {
                logger.log(.warning, "LINE search sidebar not found after Enter")
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
            if sidebarDetectedAfterSearch && !clickedSidebarResultRow {
                throw BridgeRuntimeError(
                    code: "search_result_not_found",
                    message: "No clickable search result row found",
                    retriable: true,
                    failedStep: "rescan_after_navigation",
                    details: "sidebar_detected=true"
                )
            }
            throw BridgeRuntimeError(
                code: "rescan_timeout",
                message: "Could not detect navigation to conversation",
                retriable: true,
                failedStep: "rescan_after_navigation",
                details: "messageInput not found after 3s polling"
            )
        }
        } // end if !canSkipNavigation

        // Stage 2+3: Focus input -> setValue -> verify
        // Suppress OCR polling while text is in the input field to prevent
        // the watcher from picking up our own outgoing text as inbound.
        recentSendTracker.beginSending()
        defer { recentSendTracker.endSending() }

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

            // Poll to verify value was set (short timeout to minimize OCR exposure window)
            _ = AXActions.poll(intervalMs: 20, timeoutMs: 50) {
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
            }
            AXActions.sendEnter(pid: pid)
            return true
        }

        lastConversationHint = payload.conversationHint
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
            guard let sidebar = LineSidebarDiscovery.findSidebarList(in: nodes, windowFrame: windowFrame) else {
                logger.log(.warning, "LINE sidebar discovery failed: sidebar list not visible")
                throw BridgeRuntimeError(
                    code: "sidebar_not_visible",
                    message: "Sidebar is not visible",
                    retriable: true,
                    failedStep: "get_conversations",
                    details: "sidebar_list_not_found"
                )
            }

            let windowTitle = AXQuery.copyStringAttribute(rootWindow, attribute: kAXTitleAttribute as String)
            logger.log(.info, "LINE sidebar list found rows=\(sidebar.visibleRows.count)")

            let axCandidates = LineSidebarDiscovery.extractAXConversationCandidates(
                from: sidebar.visibleRows,
                nodes: nodes,
                windowTitle: windowTitle
            )
            logger.log(.info, "LINE sidebar names ax=\(axCandidates.count) rows=\(sidebar.visibleRows.count)")

            var ocrCandidates: [LineSidebarDiscovery.SidebarConversationCandidate] = []
            var failureReason = "sidebar_rows_visible_but_names_missing"
            if axCandidates.count < min(limit, sidebar.visibleRows.count) {
                if let pid = AXQuery.pid(of: rootWindow), let windowID = AXActions.findWindowID(pid: pid) {
                    ocrCandidates = LineSidebarDiscovery.extractOCRConversationCandidates(
                        from: sidebar.visibleRows,
                        windowID: windowID,
                        config: .default,
                        windowTitle: windowTitle
                    )
                    logger.log(.info, "LINE sidebar names ocr=\(ocrCandidates.count) rows=\(sidebar.visibleRows.count)")
                    if ocrCandidates.isEmpty && axCandidates.isEmpty {
                        failureReason = "ocr_unavailable_or_empty"
                    }
                } else {
                    failureReason = "ocr_window_id_missing"
                    logger.log(.warning, "LINE sidebar OCR fallback unavailable: missing window ID")
                }
            }

            let unreadFrames = LineSidebarDiscovery.extractUnreadIndicatorFrames(
                from: nodes,
                sidebarFrame: sidebar.frame
            )
            let conversations = LineSidebarDiscovery.buildConversationEntries(
                axCandidates: axCandidates,
                ocrCandidates: ocrCandidates,
                unreadFrames: unreadFrames,
                limit: limit
            )

            guard !conversations.isEmpty else {
                let details = "\(failureReason) row_count=\(sidebar.visibleRows.count) ax_names=\(axCandidates.count) ocr_names=\(ocrCandidates.count)"
                logger.log(.warning, "LINE sidebar discovery failed: \(details)")
                throw BridgeRuntimeError(
                    code: "sidebar_not_visible",
                    message: "Sidebar is not visible",
                    retriable: true,
                    failedStep: "get_conversations",
                    details: details
                )
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
