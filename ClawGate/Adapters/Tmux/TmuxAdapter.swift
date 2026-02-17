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

    /// Returns the mode for a session: "ignore", "observe", "auto", or "autonomous".
    private func sessionMode(for session: CCStatusBarClient.CCSession) -> String {
        let modes = configStore.load().tmuxSessionModes
        return modes[AppConfig.modeKey(sessionType: session.sessionType, project: session.project)] ?? "ignore"
    }

    /// Returns sessions that have a mode set (observe or autonomous).
    private func activeSessions() -> [CCStatusBarClient.CCSession] {
        let modes = configStore.load().tmuxSessionModes
        return ccClient.allSessions().filter {
            modes[AppConfig.modeKey(sessionType: $0.sessionType, project: $0.project)] != nil
        }
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

        // Resolve session: pick the one with an authoritative mode (autonomous/auto).
        // A project may have both CC and Codex sessions; only the configured one should be used.
        let candidates = ccClient.sessions(forProject: project)
        guard !candidates.isEmpty else {
            throw BridgeRuntimeError(
                code: "session_not_found",
                message: "No Claude Code session found for project '\(project)'",
                retriable: true,
                failedStep: "resolve_target",
                details: "Available: \(ccClient.allSessions().map(\.project).joined(separator: ", "))"
            )
        }

        // Find the session whose mode allows sending (autonomous or auto)
        let sessionWithMode: (session: CCStatusBarClient.CCSession, mode: String)? = candidates.lazy.compactMap { [self] candidate in
            let m = sessionMode(for: candidate)
            return (m == "autonomous" || m == "auto") ? (candidate, m) : nil
        }.first

        guard let (session, _) = sessionWithMode else {
            // No authoritative session found — check for observe or all-ignore
            let modes = candidates.map { candidate -> (type: String, mode: String) in
                (type: candidate.sessionType, mode: self.sessionMode(for: candidate))
            }
            if let obs = modes.first(where: { $0.mode == "observe" }) {
                throw BridgeRuntimeError(
                    code: "session_read_only",
                    message: "Session '\(project)' is in observe mode (read-only)",
                    retriable: false,
                    failedStep: "resolve_target",
                    details: "sessionType=\(obs.type)"
                )
            }
            let modeDesc = modes.map { "\($0.type)=\($0.mode)" }.joined(separator: ", ")
            logger.log(.info, "Session '\(project)' not authoritative on this host (\(modeDesc))")
            throw BridgeRuntimeError(
                code: "session_not_found",
                message: "Session '\(project)' is not authoritative on this host",
                retriable: true,
                failedStep: "resolve_target",
                details: "\(modeDesc) allKeys=\(configStore.load().tmuxSessionModes.keys.sorted().joined(separator: ","))"
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

        // Step 3: Send keys (or menu selection)
        let start3 = Date()

        // Detect __cc_select:N prefix for AskUserQuestion menu navigation
        if let selectRange = payload.text.range(of: #"^__cc_select:(\d+)$"#, options: .regularExpression) {
            let indexStr = payload.text[selectRange].split(separator: ":").last.map(String.init) ?? "0"
            let optionIndex = Int(indexStr) ?? 0

            do {
                try sendMenuSelect(target: target, optionIndex: optionIndex)
                stepLogger.record(step: "menu_select", start: start3, success: true,
                                  details: "target=\(target) option=\(optionIndex)")
            } catch {
                stepLogger.record(step: "menu_select", start: start3, success: false,
                                  details: "\(error)")
                throw error
            }
        } else {
            do {
                try TmuxShell.sendKeys(target: target, text: payload.text, enter: payload.enterToSend)
                stepLogger.record(step: "send_keys", start: start3, success: true,
                                  details: "target=\(target) enter=\(payload.enterToSend)")
            } catch {
                stepLogger.record(step: "send_keys", start: start3, success: false,
                                  details: "\(error)")
                throw error
            }
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
            let key = AppConfig.modeKey(sessionType: $0.sessionType, project: $0.project)
            return $0.status == "waiting_input" && (modes[key] == "autonomous" || modes[key] == "auto")
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

    /// Check if the CC prompt marker (❯ U+276F) is visible in the pane output.
    /// Returns true if the marker is found on the last non-empty line above the status bar separator.
    /// Falls back to true (assume idle) if pane cannot be read.
    private func hasPromptMarker(target: String) -> Bool {
        guard let output = try? TmuxShell.capturePane(target: target, lines: 30) else {
            return true // Can't read pane — assume idle to avoid blocking
        }

        // Strip ANSI escape sequences
        let stripped = output.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[a-zA-Z]|\u{1B}\\][^\u{07}]*\u{07}",
            with: "",
            options: .regularExpression
        )

        let lines = stripped.components(separatedBy: "\n")

        // Scan top-to-bottom: find last non-empty line before the status bar separator (───)
        var lastContent = ""
        for line in lines {
            if line.range(of: #"^[-─━]{3,}"#, options: .regularExpression) != nil {
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lastContent = line
            }
        }

        return lastContent.contains("\u{276F}")
    }

    /// Navigate an AskUserQuestion menu and select an option by index.
    ///
    /// Strategy:
    /// 1. Capture pane to detect current selected position (look for ❯ or ●)
    /// 2. Calculate delta from current position to target index
    /// 3. Send Up/Down keys to navigate, then Enter to confirm
    /// Fallback: if detection fails, press Up×20 (go to top) then Down×N
    private func sendMenuSelect(target: String, optionIndex: Int) throws {
        let keyDelay: TimeInterval = 0.05  // 50ms between keys

        // Try to detect current selection from pane output
        var currentIndex: Int? = nil
        if let paneOutput = try? TmuxShell.capturePane(target: target, lines: 50) {
            let lines = paneOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var optIdx = 0
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let hasSelector = trimmed.contains("\u{276F}") || trimmed.contains("\u{25CF}")
                let hasBullet = trimmed.contains("\u{25CB}")
                if hasSelector {
                    currentIndex = optIdx
                    optIdx += 1
                } else if hasBullet {
                    optIdx += 1
                }
            }
        }

        if let current = currentIndex {
            // Smart navigation: move exactly the needed steps
            let delta = optionIndex - current
            if delta > 0 {
                for _ in 0..<delta {
                    try TmuxShell.sendSpecialKey(target: target, key: "Down")
                    Thread.sleep(forTimeInterval: keyDelay)
                }
            } else if delta < 0 {
                for _ in 0..<(-delta) {
                    try TmuxShell.sendSpecialKey(target: target, key: "Up")
                    Thread.sleep(forTimeInterval: keyDelay)
                }
            }
        } else {
            // Fallback: go to top, then navigate down to target
            for _ in 0..<20 {
                try TmuxShell.sendSpecialKey(target: target, key: "Up")
                Thread.sleep(forTimeInterval: keyDelay)
            }
            for _ in 0..<optionIndex {
                try TmuxShell.sendSpecialKey(target: target, key: "Down")
                Thread.sleep(forTimeInterval: keyDelay)
            }
        }

        // Confirm selection
        Thread.sleep(forTimeInterval: keyDelay)
        try TmuxShell.sendSpecialKey(target: target, key: "Enter")

        logger.log(.info, "TmuxAdapter: menu select option \(optionIndex) on \(target)")
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
