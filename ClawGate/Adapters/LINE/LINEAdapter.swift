import AppKit
import Foundation

final class LINEAdapter: AdapterProtocol {
    let name = "line"

    private let logger: AppLogger
    private let retry = RetryPolicy(maxAttempts: 2, initialDelayMs: 120)

    init(logger: AppLogger) {
        self.logger = logger
    }

    func sendMessage(payload: SendPayload) throws -> (SendResult, [StepLog]) {
        let stepLogger = StepLogger()

        try step("ensure_accessibility", logger: stepLogger) {
            guard AXIsProcessTrusted() else {
                throw BridgeRuntimeError(
                    code: "ax_permission_missing",
                    message: "アクセシビリティ権限が未付与です",
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
                    message: "LINEを起動できません",
                    retriable: true,
                    failedStep: "ensure_line_running",
                    details: "bundleIdentifier=jp.naver.line.mac"
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
            guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac").first else {
                throw BridgeRuntimeError(
                    code: "line_not_running",
                    message: "LINEの起動を確認できません",
                    retriable: true,
                    failedStep: "ensure_line_running",
                    details: "bundleIdentifier=jp.naver.line.mac"
                )
            }
            return runningApp
        }

        _ = try step("activate_line", logger: stepLogger) {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return true
        }

        let rootWindow = try step("find_main_window", logger: stepLogger) {
            let appElement = AXQuery.applicationElement(pid: app.processIdentifier)
            guard let window = AXQuery.focusedWindow(appElement: appElement) else {
                throw BridgeRuntimeError(
                    code: "line_window_missing",
                    message: "LINEのフォーカスウィンドウが見つかりません",
                    retriable: true,
                    failedStep: "find_main_window",
                    details: nil
                )
            }
            return window
        }

        let windowFrame: CGRect = try step("get_window_frame", logger: stepLogger) {
            guard let frame = AXQuery.copyFrameAttribute(rootWindow) else {
                throw BridgeRuntimeError(
                    code: "window_frame_missing",
                    message: "ウィンドウのフレーム情報が取得できません",
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

        _ = try step("open_conversation", logger: stepLogger) {
            let candidate = SelectorResolver.resolve(
                selector: LineSelectors.searchFieldU, in: nodes, windowFrame: windowFrame
            ) ?? legacyResolve(LineSelectors.searchField, in: nodes)

            guard let searchField = candidate else {
                throw BridgeRuntimeError(
                    code: "search_field_not_found",
                    message: "検索欄が見つかりません",
                    retriable: true,
                    failedStep: "open_conversation",
                    details: "selectors=LineSelectors.searchFieldU"
                )
            }
            guard AXActions.setValue(payload.conversationHint, on: searchField.node.element) else {
                throw BridgeRuntimeError(
                    code: "search_input_failed",
                    message: "宛先検索キーワードを入力できません",
                    retriable: true,
                    failedStep: "open_conversation",
                    details: payload.conversationHint
                )
            }
            AXActions.confirmEnterFallback()
            return true
        }

        nodes = try step("rescan_after_navigation", logger: stepLogger) {
            let maxAttempts = 4
            for attempt in 1...maxAttempts {
                let fresh = AXQuery.descendants(of: rootWindow)
                let found = SelectorResolver.resolve(
                    selector: LineSelectors.messageInputU, in: fresh, windowFrame: windowFrame
                ) ?? legacyResolve(LineSelectors.messageInput, in: fresh)
                if found != nil {
                    return fresh
                }
                if attempt < maxAttempts {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            throw BridgeRuntimeError(
                code: "rescan_timeout",
                message: "会話画面への遷移を検出できません",
                retriable: true,
                failedStep: "rescan_after_navigation",
                details: "messageInput not found after 2s polling"
            )
        }

        _ = try step("input_message", logger: stepLogger) {
            let candidate = SelectorResolver.resolve(
                selector: LineSelectors.messageInputU, in: nodes, windowFrame: windowFrame
            ) ?? legacyResolve(LineSelectors.messageInput, in: nodes)

            guard let input = candidate else {
                throw BridgeRuntimeError(
                    code: "message_input_not_found",
                    message: "メッセージ入力欄が見つかりません",
                    retriable: true,
                    failedStep: "input_message",
                    details: "selectors=LineSelectors.messageInputU"
                )
            }
            guard AXActions.setValue(payload.text, on: input.node.element) else {
                throw BridgeRuntimeError(
                    code: "message_set_failed",
                    message: "メッセージ本文を入力できません",
                    retriable: true,
                    failedStep: "input_message",
                    details: nil
                )
            }
            return true
        }

        _ = try step("send_message", logger: stepLogger) {
            let candidate = SelectorResolver.resolve(
                selector: LineSelectors.sendButtonU, in: nodes, windowFrame: windowFrame
            ) ?? legacyResolve(LineSelectors.sendButton, in: nodes)

            if let button = candidate, AXActions.press(button.node.element) {
                return true
            }
            if payload.enterToSend {
                AXActions.confirmEnterFallback()
                return true
            }
            throw BridgeRuntimeError(
                code: "send_action_failed",
                message: "送信アクションを実行できません",
                retriable: true,
                failedStep: "send_message",
                details: nil
            )
        }

        logger.log(.info, "LINE send flow finished for \(payload.conversationHint)")

        let result = SendResult(
            adapter: name,
            action: "send_message",
            messageID: "local-\(UUID().uuidString)",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        return (result, stepLogger.all())
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
