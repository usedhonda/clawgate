import AppKit
import Foundation

final class LINEAdapter: AdapterProtocol {
    private struct SendSurfaceAssessment {
        let hasSearchField: Bool
        let searchFieldValue: String
        let hasMessageInput: Bool
        let hasGreenSignal: Bool
        let hasTextSignal: Bool
        let matchesExpectedConversation: Bool
        let windowTitle: String?
        let reason: String

        var isAbnormal: Bool {
            !hasSearchField
                || !hasMessageInput
                || !searchFieldValue.isEmpty
                || (!hasGreenSignal && !hasTextSignal)
        }
    }

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

        let defaultConversation = configuredDefaultConversation()
        let isDefaultConversationSend =
            !defaultConversation.isEmpty
            && LineSidebarDiscovery.normalizeConversationKey(payload.conversationHint)
                == LineSidebarDiscovery.normalizeConversationKey(defaultConversation)

        // Same-conversation cache: skip search if already in the right conversation
        var canSkipNavigation = false
        var sidebarDetectedAfterSearch = false
        var clickedSidebarResultRow = false
        if !isDefaultConversationSend, let lastHint = lastConversationHint, lastHint == payload.conversationHint {
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
            if isDefaultConversationSend {
                let preflight = try step("preflight_send_surface", logger: stepLogger) {
                    try assessSendSurface(
                        rootWindow: rootWindow,
                        windowFrame: windowFrame,
                        nodes: nodes,
                        expectedConversation: defaultConversation
                    )
                }
                logger.log(
                    .info,
                    "LINE default send preflight abnormal=\(preflight.isAbnormal) reason=\(preflight.reason) search='\(preflight.searchFieldValue)' green=\(preflight.hasGreenSignal) text=\(preflight.hasTextSignal) input=\(preflight.hasMessageInput)"
                )
                if preflight.isAbnormal {
                    nodes = try step("recover_default_conversation", logger: stepLogger) {
                        try recoverDefaultConversationSurface(
                            app: app,
                            rootWindow: rootWindow,
                            windowFrame: windowFrame,
                            nodes: nodes,
                            defaultConversation: defaultConversation
                        )
                    }
                } else {
                    stepLogger.record(step: "open_conversation", start: Date(), success: true, details: "skipped (default conversation clean surface)")
                    stepLogger.record(step: "rescan_after_navigation", start: Date(), success: true, details: "skipped (default conversation clean surface)")
                }
            } else {
                do {
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

                        let activateDone = DispatchSemaphore(value: 0)
                        DispatchQueue.main.async {
                            app.activate(options: [.activateIgnoringOtherApps])
                            activateDone.signal()
                        }
                        activateDone.wait()
                        usleep(150_000)

                        AXActions.setFocused(searchField.node.element)
                        usleep(100_000)

                        guard AXActions.setValue(payload.conversationHint, on: searchField.node.element) else {
                            throw BridgeRuntimeError(
                                code: "search_set_failed",
                                message: "Failed to set search field value",
                                retriable: true,
                                failedStep: "open_conversation",
                                details: nil
                            )
                        }

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

                        AXActions.sendSearchEnter()
                        usleep(400_000)

                        let freshNodes = AXQuery.descendants(of: rootWindow)
                        let freshWindowFrame = AXQuery.copyFrameAttribute(rootWindow) ?? windowFrame
                        if let sidebar = LineSidebarDiscovery.findSidebarList(in: freshNodes, windowFrame: freshWindowFrame) {
                            sidebarDetectedAfterSearch = true
                            logger.log(.debug, "LINE search sidebar detected rows=\(sidebar.visibleRows.count)")
                            let windowTitle = AXQuery.copyStringAttribute(rootWindow, attribute: kAXTitleAttribute as String)
                            let windowID = AXQuery.pid(of: rootWindow).flatMap { AXActions.findWindowID(pid: $0) }
                            if let row = LineSidebarDiscovery.findConversationRow(
                                named: payload.conversationHint,
                                in: sidebar,
                                nodes: freshNodes,
                                windowTitle: windowTitle,
                                windowID: windowID
                            ) {
                                clickedSidebarResultRow = true
                                logger.log(.info, "LINE search result click row_y=\(Int(row.frame.minY)) rows=\(sidebar.visibleRows.count)")
                                _ = AXActions.clickAtCenter(row.element)
                            } else {
                                logger.log(.warning, "LINE search sidebar found but no matching clickable row")
                            }
                        } else {
                            logger.log(.warning, "LINE search sidebar not found after Enter")
                        }
                        return true
                    }

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
                } catch {
                    AXActions.sendEscape()
                    usleep(100_000)
                    logger.log(.warning, "Navigation failed, sent Escape to clear search: \(error)")
                    throw error
                }
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

        // Dismiss search mode after successful send so sidebar returns to conversation list.
        // This prevents stale search text from polluting OCR on subsequent inbound polls.
        if !canSkipNavigation && !isDefaultConversationSend {
            AXActions.sendEscape()
            usleep(100_000)
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

    private func configuredDefaultConversation() -> String {
        ConfigStore().load().lineDefaultConversation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assessSendSurface(
        rootWindow: AXUIElement,
        windowFrame: CGRect,
        nodes: [AXNode],
        expectedConversation: String? = nil
    ) throws -> SendSurfaceAssessment {
        let windowTitle = AXQuery.copyStringAttribute(rootWindow, attribute: kAXTitleAttribute as String)
        let searchField = SelectorResolver.resolve(
            selector: LineSelectors.searchFieldU, in: nodes, windowFrame: windowFrame
        ) ?? legacyResolve(LineSelectors.searchField, in: nodes)
        let searchFieldValue = searchField.flatMap {
            AXQuery.copyStringAttribute($0.node.element, attribute: kAXValueAttribute as String)
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasMessageInput = (SelectorResolver.resolve(
            selector: LineSelectors.messageInputU, in: nodes, windowFrame: windowFrame
        ) ?? legacyResolve(LineSelectors.messageInput, in: nodes)) != nil

        let hasVisibleMessageText = nodes.contains { node in
            guard node.role == "AXStaticText", let frame = node.frame else { return false }
            let relX = Double(frame.midX - windowFrame.origin.x) / Double(windowFrame.width)
            let relY = Double(frame.midY - windowFrame.origin.y) / Double(windowFrame.height)
            guard let geo = LineSelectors.messageTextU.geometryHint,
                  geo.regionX.contains(relX),
                  geo.regionY.contains(relY) else {
                return false
            }
            let text = (node.value ?? node.title ?? node.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && !Self.isUIChrome(text, windowTitle: windowTitle)
        }

        let hasSidebarTextSignal: Bool = {
            guard let sidebar = LineSidebarDiscovery.findSidebarList(in: nodes, windowFrame: windowFrame) else {
                return false
            }
            let axCandidates = LineSidebarDiscovery.extractAXConversationCandidates(
                from: sidebar.visibleRows,
                nodes: nodes,
                windowTitle: windowTitle
            )
            if !axCandidates.isEmpty {
                return true
            }
            guard let pid = AXQuery.pid(of: rootWindow),
                  let windowID = AXActions.findWindowID(pid: pid) else {
                return false
            }
            let ocrCandidates = LineSidebarDiscovery.extractOCRConversationCandidates(
                from: sidebar.visibleRows,
                windowID: windowID,
                config: .default,
                windowTitle: windowTitle
            )
            return !ocrCandidates.isEmpty
        }()

        let hasConversationTitleSignal: Bool = {
            guard let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return false
            }
            return title.caseInsensitiveCompare("LINE") != .orderedSame
                && !Self.isUIChrome(title, windowTitle: nil)
        }()

        let hasTextSignal = hasVisibleMessageText || hasSidebarTextSignal || hasConversationTitleSignal
        let matchesExpectedConversation: Bool = {
            let expected = expectedConversation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !expected.isEmpty else { return true }
            guard let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return false
            }
            return LineSidebarDiscovery.normalizeConversationKey(title)
                == LineSidebarDiscovery.normalizeConversationKey(expected)
        }()
        let hasGreenSignal: Bool = {
            guard let pid = AXQuery.pid(of: rootWindow),
                  let windowID = AXActions.findWindowID(pid: pid) else {
                return false
            }
            return detectGreenSignal(in: messageSignalRect(for: windowFrame), windowID: windowID)
        }()

        let reason: String
        if searchField == nil {
            reason = "search_field_missing"
        } else if !searchFieldValue.isEmpty {
            reason = "search_field_dirty"
        } else if !hasMessageInput {
            reason = "message_input_missing"
        } else if !hasGreenSignal && !hasTextSignal {
            reason = "no_green_or_text_signal"
        } else {
            reason = "ok"
        }

        return SendSurfaceAssessment(
            hasSearchField: searchField != nil,
            searchFieldValue: searchFieldValue,
            hasMessageInput: hasMessageInput,
            hasGreenSignal: hasGreenSignal,
            hasTextSignal: hasTextSignal,
            matchesExpectedConversation: matchesExpectedConversation,
            windowTitle: windowTitle,
            reason: reason
        )
    }

    private func recoverDefaultConversationSurface(
        app: NSRunningApplication,
        rootWindow: AXUIElement,
        windowFrame: CGRect,
        nodes: [AXNode],
        defaultConversation: String
    ) throws -> [AXNode] {
        activate(app: app)

        if let searchField = SelectorResolver.resolve(
            selector: LineSelectors.searchFieldU, in: nodes, windowFrame: windowFrame
        ) ?? legacyResolve(LineSelectors.searchField, in: nodes) {
            let searchValue = AXQuery.copyStringAttribute(
                searchField.node.element,
                attribute: kAXValueAttribute as String
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !searchValue.isEmpty {
                AXActions.setFocused(searchField.node.element)
                usleep(80_000)
                AXActions.sendEscape()
                usleep(140_000)
            }
        }

        let initialAssessment = try assessSendSurface(
            rootWindow: rootWindow,
            windowFrame: windowFrame,
            nodes: nodes,
            expectedConversation: defaultConversation
        )
        if !initialAssessment.hasGreenSignal && !initialAssessment.hasTextSignal {
            let didClickPane = clickChatRailPoint(in: windowFrame)
            logger.log(.info, "LINE default recovery pane_click=\(didClickPane)")
            if didClickPane {
                usleep(180_000)
            }
        }

        var freshNodes = AXQuery.descendants(of: rootWindow)
        let freshWindowFrame = AXQuery.copyFrameAttribute(rootWindow) ?? windowFrame
        guard let sidebar = LineSidebarDiscovery.findSidebarList(in: freshNodes, windowFrame: freshWindowFrame) else {
            throw BridgeRuntimeError(
                code: "sidebar_not_visible",
                message: "Sidebar is not visible during default conversation recovery",
                retriable: true,
                failedStep: "recover_default_conversation",
                details: "sidebar_list_not_found"
            )
        }

        let windowTitle = AXQuery.copyStringAttribute(rootWindow, attribute: kAXTitleAttribute as String)
        let windowID = AXQuery.pid(of: rootWindow).flatMap { AXActions.findWindowID(pid: $0) }
        guard let row = LineSidebarDiscovery.findConversationRow(
            named: defaultConversation,
            in: sidebar,
            nodes: freshNodes,
            windowTitle: windowTitle,
            windowID: windowID
        ) else {
            throw BridgeRuntimeError(
                code: "default_conversation_not_found",
                message: "Default conversation row not found",
                retriable: true,
                failedStep: "recover_default_conversation",
                details: defaultConversation
            )
        }

        _ = AXActions.clickAtCenter(row.element)
        usleep(250_000)

        let found = AXActions.poll(intervalMs: 100, timeoutMs: 3000) {
            let currentNodes = AXQuery.descendants(of: rootWindow)
            let currentFrame = AXQuery.copyFrameAttribute(rootWindow) ?? freshWindowFrame
            return (SelectorResolver.resolve(
                selector: LineSelectors.messageInputU, in: currentNodes, windowFrame: currentFrame
            ) ?? self.legacyResolve(LineSelectors.messageInput, in: currentNodes)) != nil
        }

        freshNodes = AXQuery.descendants(of: rootWindow)
        let recoveredFrame = AXQuery.copyFrameAttribute(rootWindow) ?? freshWindowFrame
        let recoveredAssessment = try assessSendSurface(
            rootWindow: rootWindow,
            windowFrame: recoveredFrame,
            nodes: freshNodes,
            expectedConversation: defaultConversation
        )
        logger.log(
            .info,
            "LINE default recovery rerun abnormal=\(recoveredAssessment.isAbnormal) reason=\(recoveredAssessment.reason) search='\(recoveredAssessment.searchFieldValue)' green=\(recoveredAssessment.hasGreenSignal) text=\(recoveredAssessment.hasTextSignal)"
        )
        guard found, !recoveredAssessment.isAbnormal else {
            throw BridgeRuntimeError(
                code: "default_surface_recovery_failed",
                message: "Default conversation surface remained abnormal after recovery",
                retriable: true,
                failedStep: "recover_default_conversation",
                details: "reason=\(recoveredAssessment.reason)"
            )
        }

        return freshNodes
    }

    private func activate(app: NSRunningApplication) {
        let activateDone = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            app.activate(options: [.activateIgnoringOtherApps])
            activateDone.signal()
        }
        activateDone.wait()
        usleep(150_000)
    }

    private func messageSignalRect(for windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX + windowFrame.width * 0.24,
            y: windowFrame.minY + windowFrame.height * 0.08,
            width: windowFrame.width * 0.72,
            height: windowFrame.height * 0.70
        ).integral
    }

    private func detectGreenSignal(in screenRect: CGRect, windowID: CGWindowID) -> Bool {
        guard screenRect.width > 20, screenRect.height > 20,
              let rawImage = VisionOCR.captureInboundDebugImages(from: screenRect, windowID: windowID)?.raw,
              let rgba = rgbaBuffer(from: rawImage) else {
            return false
        }

        let minGreenPixelsPerRow = max(8, rgba.width / 28)
        var greenRows = 0
        for y in 0..<rgba.height {
            let rowStart = y * rgba.bytesPerRow
            var rowGreen = 0
            for x in 0..<rgba.width {
                let i = rowStart + x * 4
                let r = Int(rgba.data[i])
                let g = Int(rgba.data[i + 1])
                let b = Int(rgba.data[i + 2])
                if isLikelyLineGreen(r: r, g: g, b: b) {
                    rowGreen += 1
                    if rowGreen >= minGreenPixelsPerRow {
                        greenRows += 1
                        break
                    }
                }
            }
            if greenRows >= 4 {
                return true
            }
        }
        return false
    }

    private func rgbaBuffer(from image: CGImage) -> (data: [UInt8], width: Int, height: Int, bytesPerRow: Int)? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (buffer, width, height, bytesPerRow)
    }

    private func isLikelyLineGreen(r: Int, g: Int, b: Int) -> Bool {
        g >= 165 && r >= 150 && b <= 190 && (g - r) >= 12 && (g - b) >= 18
    }

    private func clickChatRailPoint(in windowFrame: CGRect) -> Bool {
        let x = windowFrame.minX + min(max(22, windowFrame.width * 0.03), 34)
        let y = windowFrame.minY + min(max(150, windowFrame.height * 0.18), 210)
        return click(point: CGPoint(x: x, y: y))
    }

    @discardableResult
    private func click(point: CGPoint, restoreCursor: Bool = true) -> Bool {
        let savedPos = restoreCursor ? CGEvent(source: nil)?.location : nil
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
        usleep(20_000)
        downEvent?.post(tap: .cghidEventTap)
        usleep(20_000)
        upEvent?.post(tap: .cghidEventTap)
        if let savedPos {
            let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: savedPos, mouseButton: .left)
            restoreEvent?.post(tap: .cghidEventTap)
        }
        return downEvent != nil && upEvent != nil
    }

    // MARK: - Navigate to conversation (no send)

    /// Navigate LINE to the given conversation without sending a message.
    /// Returns true if the input field is present after navigation.
    func navigateToConversation(hint: String) throws -> Bool {
        let app: NSRunningApplication = try {
            guard let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first else {
                throw BridgeRuntimeError(
                    code: "line_not_running",
                    message: "LINE is not running",
                    retriable: false, failedStep: "ensure_line_running", details: nil
                )
            }
            return running
        }()

        let pid = app.processIdentifier
        let appElement = AXQuery.applicationElement(pid: pid)
        guard let rootWindow = AXActions.ensureWindow(
            app: app, appElement: appElement, bundleID: bundleIdentifier
        ) else {
            throw BridgeRuntimeError(
                code: "window_not_found",
                message: "LINE window not found",
                retriable: true, failedStep: "find_window", details: nil
            )
        }

        let windowFrame = AXQuery.copyFrameAttribute(rootWindow) ?? .zero
        var nodes = AXQuery.descendants(of: rootWindow)
        let defaultConversation = configuredDefaultConversation()
        let isDefaultConversationHint =
            !defaultConversation.isEmpty
            && LineSidebarDiscovery.normalizeConversationKey(hint)
                == LineSidebarDiscovery.normalizeConversationKey(defaultConversation)

        // Already in chat view with input field?
        if !isDefaultConversationHint, (SelectorResolver.resolve(
            selector: LineSelectors.messageInputU, in: nodes, windowFrame: windowFrame
        ) ?? legacyResolve(LineSelectors.messageInput, in: nodes)) != nil {
            logger.log(.info, "ensureConversation: already in chat view")
            lastConversationHint = hint
            return true
        }

        if isDefaultConversationHint {
            let assessment = try assessSendSurface(
                rootWindow: rootWindow,
                windowFrame: windowFrame,
                nodes: nodes,
                expectedConversation: defaultConversation
            )
            logger.log(.info, "ensureConversation default preflight abnormal=\(assessment.isAbnormal) reason=\(assessment.reason) search='\(assessment.searchFieldValue)'")
            if !assessment.isAbnormal {
                lastConversationHint = hint
                return assessment.hasMessageInput
            }

            nodes = try recoverDefaultConversationSurface(
                app: app,
                rootWindow: rootWindow,
                windowFrame: windowFrame,
                nodes: nodes,
                defaultConversation: defaultConversation
            )
            lastConversationHint = hint
            return (SelectorResolver.resolve(
                selector: LineSelectors.messageInputU, in: nodes, windowFrame: AXQuery.copyFrameAttribute(rootWindow) ?? windowFrame
            ) ?? legacyResolve(LineSelectors.messageInput, in: nodes)) != nil
        }

        // Navigate: search -> click
        guard let searchField = SelectorResolver.resolve(
            selector: LineSelectors.searchFieldU, in: nodes, windowFrame: windowFrame
        ) ?? legacyResolve(LineSelectors.searchField, in: nodes) else {
            throw BridgeRuntimeError(
                code: "search_field_not_found",
                message: "Search field not found",
                retriable: true, failedStep: "ensure_conversation", details: nil
            )
        }

        let activateDone = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            app.activate(options: [.activateIgnoringOtherApps])
            activateDone.signal()
        }
        activateDone.wait()
        usleep(150_000)

        AXActions.setFocused(searchField.node.element)
        usleep(100_000)

        guard AXActions.setValue(hint, on: searchField.node.element) else {
            throw BridgeRuntimeError(
                code: "search_set_failed",
                message: "Failed to set search field value",
                retriable: true, failedStep: "ensure_conversation", details: nil
            )
        }

        let verified = AXActions.poll(intervalMs: 30, timeoutMs: 500) {
            let val = AXQuery.copyStringAttribute(searchField.node.element, attribute: kAXValueAttribute as String) ?? ""
            return !val.isEmpty
        }
        guard verified else {
            throw BridgeRuntimeError(
                code: "search_value_empty",
                message: "Search field value empty after setValue",
                retriable: true, failedStep: "ensure_conversation", details: nil
            )
        }

        AXActions.sendSearchEnter()
        usleep(400_000)

        let freshNodes = AXQuery.descendants(of: rootWindow)
        let freshWindowFrame = AXQuery.copyFrameAttribute(rootWindow) ?? windowFrame
        let windowTitle = AXQuery.copyStringAttribute(rootWindow, attribute: kAXTitleAttribute as String)
        let windowID = AXQuery.pid(of: rootWindow).flatMap { AXActions.findWindowID(pid: $0) }
        if let sidebar = LineSidebarDiscovery.findSidebarList(in: freshNodes, windowFrame: freshWindowFrame),
           let row = LineSidebarDiscovery.findConversationRow(
               named: hint,
               in: sidebar,
               nodes: freshNodes,
               windowTitle: windowTitle,
               windowID: windowID
           ) {
            logger.log(.info, "ensureConversation: clicking sidebar row")
            _ = AXActions.clickAtCenter(row.element)
        }

        // Poll for messageInput to confirm navigation succeeded
        let found = AXActions.poll(intervalMs: 100, timeoutMs: 3000) {
            let n = AXQuery.descendants(of: rootWindow)
            let wf = AXQuery.copyFrameAttribute(rootWindow) ?? windowFrame
            return (SelectorResolver.resolve(
                selector: LineSelectors.messageInputU, in: n, windowFrame: wf
            ) ?? self.legacyResolve(LineSelectors.messageInput, in: n)) != nil
        }

        if !found {
            AXActions.sendEscape()
            usleep(100_000)
            logger.log(.warning, "ensureConversation: navigation failed, sent Escape")
            return false
        }

        // Dismiss search mode after successful navigation to prevent stale search text
        // from polluting the search field (e.g. "heartbeat" written by external agents)
        AXActions.sendEscape()
        usleep(100_000)

        lastConversationHint = hint
        logger.log(.info, "ensureConversation: navigated to '\(hint)'")
        return true
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
