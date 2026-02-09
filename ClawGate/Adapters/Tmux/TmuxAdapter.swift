import Foundation

/// Adapter that sends messages to Claude Code running in tmux panes.
/// Uses `TmuxShell` for tmux CLI interaction and `CCStatusBarClient` for session discovery.
final class TmuxAdapter: AdapterProtocol {
    let name = "tmux"
    let bundleIdentifier = "" // No AX dump support

    private let ccClient: CCStatusBarClient
    private let configStore: ConfigStore
    private let logger: AppLogger

    init(ccClient: CCStatusBarClient, configStore: ConfigStore, logger: AppLogger) {
        self.ccClient = ccClient
        self.configStore = configStore
        self.logger = logger
    }

    /// Returns the mode for a project: "ignore", "observe", or "autonomous".
    private func sessionMode(for project: String) -> String {
        let modes = configStore.load().tmuxSessionModes
        return modes[project] ?? "ignore"
    }

    /// Returns sessions that have a mode set (observe or autonomous).
    private func activeSessions() -> [CCStatusBarClient.CCSession] {
        let modes = configStore.load().tmuxSessionModes
        return ccClient.allSessions().filter { modes[$0.project] != nil }
    }

    func sendMessage(payload: SendPayload) throws -> (SendResult, [StepLog]) {
        let stepLogger = StepLogger()

        // Step 1: Resolve target session
        let start1 = Date()
        let project = payload.conversationHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else {
            throw BridgeRuntimeError(
                code: "invalid_conversation_hint",
                message: "conversation_hint (project name) is required for tmux adapter",
                retriable: false,
                failedStep: "resolve_target",
                details: nil
            )
        }

        // Check session mode — only autonomous can send
        let mode = sessionMode(for: project)
        guard mode == "autonomous" else {
            let errorCode = mode == "observe" ? "session_read_only" : "session_not_allowed"
            let errorMsg = mode == "observe"
                ? "Session '\(project)' is in observe mode (read-only)"
                : "Session '\(project)' is not enabled"
            throw BridgeRuntimeError(
                code: errorCode,
                message: errorMsg,
                retriable: false,
                failedStep: "resolve_target",
                details: "mode=\(mode)"
            )
        }

        guard let session = ccClient.session(forProject: project) else {
            throw BridgeRuntimeError(
                code: "session_not_found",
                message: "No Claude Code session found for project '\(project)'",
                retriable: true,
                failedStep: "resolve_target",
                details: "Available: \(ccClient.allSessions().map(\.project).joined(separator: ", "))"
            )
        }

        guard let target = session.tmuxTarget else {
            throw BridgeRuntimeError(
                code: "tmux_target_missing",
                message: "Session '\(project)' has no tmux target",
                retriable: true,
                failedStep: "resolve_target",
                details: "Session status: \(session.status)"
            )
        }
        stepLogger.record(step: "resolve_target", start: start1, success: true,
                          details: "project=\(project) target=\(target) status=\(session.status)")

        // Step 2: Check session is ready for input
        let start2 = Date()
        guard session.status == "waiting_input" else {
            stepLogger.record(step: "check_status", start: start2, success: false,
                              details: "status=\(session.status), expected waiting_input")
            throw BridgeRuntimeError(
                code: "session_busy",
                message: "Claude Code session '\(project)' is currently \(session.status)",
                retriable: true,
                failedStep: "check_status",
                details: "Wait for the current task to complete before sending a new one"
            )
        }
        stepLogger.record(step: "check_status", start: start2, success: true,
                          details: "status=waiting_input")

        // Step 3: Send keys
        let start3 = Date()
        do {
            try TmuxShell.sendKeys(target: target, text: payload.text, enter: payload.enterToSend)
            stepLogger.record(step: "send_keys", start: start3, success: true,
                              details: "target=\(target) enter=\(payload.enterToSend)")
        } catch {
            stepLogger.record(step: "send_keys", start: start3, success: false,
                              details: "\(error)")
            throw error
        }

        let result = SendResult(
            adapter: name,
            action: "send_message",
            messageID: UUID().uuidString,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        logger.log(.info, "TmuxAdapter: sent to \(target) (\(payload.text.prefix(60))...)")
        return (result, stepLogger.all())
    }

    func getContext() throws -> ConversationContext {
        let filtered = activeSessions()
        let modes = configStore.load().tmuxSessionModes

        // hasInputField = true only if any autonomous session is waiting_input
        let hasReady = filtered.contains {
            $0.status == "waiting_input" && modes[$0.project] == "autonomous"
        }

        return ConversationContext(
            adapter: name,
            conversationName: filtered.first?.project,
            hasInputField: hasReady,
            windowTitle: "Claude Code (\(filtered.count) sessions)",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    func getMessages(limit: Int) throws -> MessageList {
        // Capture pane output from the first active session (observe or autonomous)
        let filtered = activeSessions()

        guard let session = filtered.first, let target = session.tmuxTarget else {
            return MessageList(
                adapter: name,
                conversationName: nil,
                messages: [],
                messageCount: 0,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
        }

        let output = try TmuxShell.capturePane(target: target, lines: limit)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let messages = lines.enumerated().map { i, line in
            VisibleMessage(text: String(line), sender: "other", yOrder: i)
        }

        return MessageList(
            adapter: name,
            conversationName: session.project,
            messages: Array(messages.suffix(limit)),
            messageCount: messages.count,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    func getConversations(limit: Int) throws -> ConversationList {
        // Only show observe/autonomous sessions (ignore sessions are hidden)
        let filtered = activeSessions()

        let entries = filtered.enumerated().map { i, session in
            ConversationEntry(
                name: session.project,
                yOrder: i,
                hasUnread: session.status == "waiting_input" && session.attentionLevel > 0
            )
        }

        return ConversationList(
            adapter: name,
            conversations: Array(entries.prefix(limit)),
            count: entries.count,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}
