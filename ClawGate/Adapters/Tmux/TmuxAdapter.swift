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

    /// Returns all sessions discovered from cc-status-bar, regardless of mode.
    private func discoveredSessions() -> [CCStatusBarClient.CCSession] {
        ccClient.allSessions()
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

        // Step 3: Pre-flight draft guard (non menu-select only)
        let isMenuSelect = payload.text.range(of: #"^__cc_select:(\d+)$"#, options: .regularExpression) != nil
        if !isMenuSelect {
            let start3 = Date()
            let draftState = detectPromptDraftState(target: target)
            switch draftState.state {
            case .idle:
                stepLogger.record(step: "check_prompt_draft", start: start3, success: true, details: draftState.reason)
            case .typing:
                stepLogger.record(step: "check_prompt_draft", start: start3, success: false, details: "draft_detected")
                throw BridgeRuntimeError(
                    code: "session_typing_busy",
                    message: "Session '\(project)' has unsent input in terminal",
                    retriable: true,
                    failedStep: "check_prompt_draft",
                    details: "draft=\(draftState.draft.prefix(120))"
                )
            case .unknown:
                stepLogger.record(step: "check_prompt_draft", start: start3, success: false, details: draftState.reason)
                throw BridgeRuntimeError(
                    code: "session_typing_busy",
                    message: "Session '\(project)' prompt state is unknown (\(draftState.reason)); skipped send to avoid overwriting input",
                    retriable: true,
                    failedStep: "check_prompt_draft",
                    details: nil
                )
            }
        }

        // Step 4: Send keys (or menu selection)
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

    /// Capture pane output for a specific project by name.
    /// Searches all known sessions (not just active/configured ones) so the reviewer agent can inspect any tmux pane.
    func getMessages(limit: Int, forProject project: String) throws -> MessageList {
        let candidates = ccClient.sessions(forProject: project)
        guard let session = candidates.first, let target = session.tmuxTarget else {
            throw BridgeRuntimeError(
                code: "session_not_found",
                message: "No tmux session found for project '\(project)'",
                retriable: false,
                failedStep: "resolve_target",
                details: "Available: \(ccClient.allSessions().map(\.project).joined(separator: ", "))"
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

    private enum PromptDraftState {
        case idle
        case typing
        case unknown
    }

    private struct PromptDraftDetection {
        let state: PromptDraftState
        let draft: String
        let reason: String
    }

    private func detectPromptDraftState(target: String) -> PromptDraftDetection {
        guard let output = try? TmuxShell.capturePane(target: target, lines: 120) else {
            return PromptDraftDetection(state: .unknown, draft: "", reason: "capture_failed")
        }

        let stripped = output.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[a-zA-Z]|\u{1B}\\][^\u{07}]*\u{07}",
            with: "",
            options: .regularExpression
        )

        let source = stripped.components(separatedBy: "\n")
        guard !source.isEmpty else {
            return PromptDraftDetection(state: .unknown, draft: "", reason: "empty_capture")
        }

        let tail = Array(source.suffix(48))
        var end = tail.count - 1
        while end >= 0 && tail[end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }
        if end < 0 {
            return PromptDraftDetection(state: .unknown, draft: "", reason: "blank_capture")
        }

        while end >= 0 && (isTmuxFooterLine(tail[end]) || isTmuxDividerLine(tail[end])) {
            end -= 1
        }
        if end < 0 {
            return PromptDraftDetection(state: .unknown, draft: "", reason: "footer_only_capture")
        }

        let searchStart = max(0, end - 16)
        var promptIndex = -1
        if end >= searchStart {
            for idx in stride(from: end, through: searchStart, by: -1) {
                if tail[idx].range(of: #"^\s*[›❯>]\s*"#, options: .regularExpression) != nil {
                    promptIndex = idx
                    break
                }
            }
        }

        if promptIndex < 0 {
            return PromptDraftDetection(state: .unknown, draft: "", reason: "prompt_not_found")
        }
        if end - promptIndex > 8 {
            return PromptDraftDetection(state: .unknown, draft: "", reason: "prompt_too_far_from_bottom")
        }

        var draftParts: [String] = []
        let firstDraft = tail[promptIndex]
            .replacingOccurrences(of: #"^\s*[›❯>]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[▌█▋▍▎▏]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !firstDraft.isEmpty {
            draftParts.append(firstDraft)
        }

        let continuationEnd = min(end, promptIndex + 2)
        if continuationEnd >= promptIndex + 1 {
            for idx in (promptIndex + 1)...continuationEnd {
                let line = tail[idx]
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if isTmuxFooterLine(line) || isTmuxDividerLine(line) || line.range(of: #"^\s*[›❯>]\s*"#, options: .regularExpression) != nil {
                    break
                }
                let normalized = line
                    .replacingOccurrences(of: #"[▌█▋▍▎▏]+$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    draftParts.append(normalized)
                }
            }
        }

        let draft = draftParts
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if draft.isEmpty {
            return PromptDraftDetection(state: .idle, draft: "", reason: "prompt_idle")
        }
        if isTemplatePromptDraft(draft) {
            return PromptDraftDetection(state: .idle, draft: "", reason: "template_prompt_idle")
        }
        return PromptDraftDetection(state: .typing, draft: draft, reason: "draft_detected")
    }

    private func isTmuxFooterLine(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return false }
        if s.contains("? for shortcuts") { return true }
        if s.range(of: #"^\d+%\s+context left$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^\d+%\s+context window$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"\d+%\s+context left"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"\d+%\s+context window"#, options: .regularExpression) != nil { return true }
        if s.hasPrefix("autonomous: ") { return true }
        return false
    }

    private func isTemplatePromptDraft(_ draft: String) -> Bool {
        let s = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return false }
        if s == "implement {feature}" { return true }
        if s == "run /review on my current changes" { return true }
        return false
    }

    private func isTmuxDividerLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[-─━]{3,}$"#, options: .regularExpression) != nil
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
        // Show all discovered sessions so mode can be changed from ignore -> observe/auto/autonomous.
        let sessions = discoveredSessions()
        let statusPriority = ["running": 2, "waiting_input": 1]
        var bestByProject: [String: CCStatusBarClient.CCSession] = [:]
        for session in sessions {
            if let existing = bestByProject[session.project] {
                let existingScore = statusPriority[existing.status] ?? 0
                let nextScore = statusPriority[session.status] ?? 0
                if nextScore > existingScore {
                    bestByProject[session.project] = session
                } else if nextScore == existingScore {
                    // Stable tie-breaker: prefer codex when both are equally active.
                    if existing.sessionType != "codex" && session.sessionType == "codex" {
                        bestByProject[session.project] = session
                    }
                }
            } else {
                bestByProject[session.project] = session
            }
        }
        let filtered = bestByProject.values.sorted { $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending }

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
