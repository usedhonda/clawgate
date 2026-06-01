import Foundation

/// Direct tmux-backed session source used when cc-status-bar is unavailable.
///
/// The poller mirrors the `TmuxSessionSource` surface so startup code can swap
/// the source without changing downstream consumers.
final class TmuxDirectPoller: TmuxSessionSource {
    struct DiagnosticsSnapshot: Codable {
        struct RejectedPaneSample: Codable {
            let target: String
            let title: String
            let currentCommand: String
            let currentPath: String
            let panePID: Int32
            let rejectReason: String

            enum CodingKeys: String, CodingKey {
                case target
                case title
                case currentCommand = "current_command"
                case currentPath = "current_path"
                case panePID = "pane_pid"
                case rejectReason = "reject_reason"
            }
        }

        let rawPaneCount: Int
        let builtSessionCount: Int
        let rejectedPaneSamples: [RejectedPaneSample]
        let lastTmuxError: String?
        let lastPollAt: Date?

        enum CodingKeys: String, CodingKey {
            case rawPaneCount = "raw_pane_count"
            case builtSessionCount = "built_session_count"
            case rejectedPaneSamples = "rejected_pane_samples"
            case lastTmuxError = "last_tmux_error"
            case lastPollAt = "last_poll_at"
        }

        static let empty = DiagnosticsSnapshot(
            rawPaneCount: 0,
            builtSessionCount: 0,
            rejectedPaneSamples: [],
            lastTmuxError: nil,
            lastPollAt: nil
        )
    }

    var onStateChange: ((SessionSnapshot, String, String) -> Void)?
    var onProgress: ((SessionSnapshot) -> Void)?
    var onSessionsChanged: (() -> Void)?

    private let logger: AppLogger
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "clawgate.tmux.direct-poller", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var sessions: [String: SessionSnapshot] = [:]
    private var _lastSuccessfulPollAt: Date?
    private var diagnostics = DiagnosticsSnapshot.empty

    var lastSuccessfulPollAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastSuccessfulPollAt
    }

    var observedSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    var configuredPollInterval: TimeInterval { pollInterval }

    var diagnosticsSnapshot: DiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return diagnostics
    }

    init(logger: AppLogger, pollInterval: TimeInterval = 20) {
        self.logger = logger
        self.pollInterval = pollInterval
    }

    func connect() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now() + 0.1, repeating: pollInterval)
        newTimer.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        self.timer = newTimer
        newTimer.resume()
        logger.log(.info, "TmuxDirectPoller: started")
    }

    func disconnect() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        sessions.removeAll()
        lock.unlock()
        timer?.cancel()
        logger.log(.info, "TmuxDirectPoller: stopped")
    }

    func session(forProject project: String) -> SessionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.first { $0.project == project }
    }

    func sessions(forProject project: String) -> [SessionSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.filter { $0.project == project }
    }

    func allSessions() -> [SessionSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.sorted { $0.project < $1.project }
    }

    private func pollOnce() {
        let pollAt = Date()
        let descriptors: [TmuxShell.PaneDescriptor]
        do {
            descriptors = try TmuxShell.listPanes()
        } catch {
            lock.lock()
            diagnostics = DiagnosticsSnapshot(
                rawPaneCount: 0,
                builtSessionCount: 0,
                rejectedPaneSamples: diagnostics.rejectedPaneSamples,
                lastTmuxError: String(describing: error),
                lastPollAt: pollAt
            )
            lock.unlock()
            logger.log(.debug, "TmuxDirectPoller: list-panes failed: \(error)")
            return
        }

        // Build snapshots per pane, then select representative per logicalKey
        var perPane: [SessionSnapshot] = []
        var rejectedPaneSamples: [DiagnosticsSnapshot.RejectedPaneSample] = []
        for pane in descriptors {
            if let session = buildSession(from: pane) {
                perPane.append(session)
            } else if rejectedPaneSamples.count < 5 {
                rejectedPaneSamples.append(makeRejectedPaneSample(from: pane))
            }
        }

        // Group by logicalKey and pick representative (attached > stable sort by target)
        let grouped = Dictionary(grouping: perPane) { $0.logicalKey }
        var next: [String: SessionSnapshot] = [:]
        for (_, candidates) in grouped {
            let representative = pickRepresentative(from: candidates)
            next[representative.sourceID] = representative
        }

        let previous: [String: SessionSnapshot]
        lock.lock()
        previous = sessions
        sessions = next
        _lastSuccessfulPollAt = Date()
        diagnostics = DiagnosticsSnapshot(
            rawPaneCount: descriptors.count,
            builtSessionCount: perPane.count,
            rejectedPaneSamples: rejectedPaneSamples,
            lastTmuxError: nil,
            lastPollAt: pollAt
        )
        lock.unlock()

        for (id, session) in next {
            if let old = previous[id] {
                if old.status != session.status {
                    onStateChange?(session, old.status, session.status)
                }
                if old.paneCapture != session.paneCapture {
                    onProgress?(session)
                }
            } else {
                onSessionsChanged?()
                if session.status == "waiting_input" {
                    onStateChange?(session, "bootstrap", "waiting_input")
                }
            }
        }

        let removed = Set(previous.keys).subtracting(next.keys)
        if !removed.isEmpty || Set(previous.keys) != Set(next.keys) {
            onSessionsChanged?()
        }
    }

    private func buildSession(from pane: TmuxShell.PaneDescriptor) -> SessionSnapshot? {
        guard let sessionType = inferSessionType(from: pane) else { return nil }
        let capture = (try? TmuxShell.capturePane(target: pane.target, lines: 120))?.trimmingCharacters(in: .newlines)
        let project = inferProject(from: pane)
        let promptClassification = classifyPromptState(capture: capture ?? "")
        let promptState = promptClassification.state
        logger.log(
            .debug,
            "TmuxDirectPoller: classify target=\(pane.target) project=\(project) classified=\(promptState.rawValue) lastPromptLine=\(promptClassification.lastPromptLine ?? "nil")"
        )
        let rootHint = inferRootHint(from: pane)

        // Raw facts only. Question parse & structured data are handled by TmuxInboundWatcher.
        // Here we only set tentative waitingReason based on pane content heuristics.
        let waitingReason: String?
        switch promptState {
        case .waitingInput:
            waitingReason = detectPermissionPrompt(in: capture) ? "permission_prompt" : nil
        case .running:
            waitingReason = nil
        }

        let sourceID = "\(pane.session):\(pane.window).\(pane.pane)"
        let logicalKey = SessionSnapshot.makeLogicalKey(
            sessionType: sessionType,
            project: project,
            rootHint: rootHint
        )

        return SessionSnapshot(
            id: sourceID,
            sourceID: sourceID,
            logicalKey: logicalKey,
            project: project,
            sessionType: sessionType,
            tmuxSession: pane.session,
            tmuxWindow: pane.window,
            tmuxPane: pane.pane,
            status: promptState.rawValue,
            waitingReason: waitingReason,
            attentionLevel: promptState == .waitingInput ? 1 : 0,
            questionText: nil,
            questionOptions: nil,
            questionSelected: nil,
            paneCapture: capture,
            captureSource: .tmuxDirect,
            isAttached: pane.isAttached
        )
    }

    private func makeRejectedPaneSample(from pane: TmuxShell.PaneDescriptor) -> DiagnosticsSnapshot.RejectedPaneSample {
        DiagnosticsSnapshot.RejectedPaneSample(
            target: pane.target,
            title: pane.title,
            currentCommand: pane.currentCommand,
            currentPath: pane.currentPath,
            panePID: pane.panePID,
            rejectReason: "unclassified(title=\(diagnosticValue(pane.title)),cmd=\(diagnosticValue(pane.currentCommand)))"
        )
    }

    private func diagnosticValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "<empty>" : trimmed
    }

    /// Pick representative snapshot from same-logicalKey candidates.
    /// Priority: attached > stable sort by tmuxTarget > first.
    private func pickRepresentative(from candidates: [SessionSnapshot]) -> SessionSnapshot {
        if candidates.count == 1 { return candidates[0] }
        if let attached = candidates.first(where: { $0.isAttached }) {
            return attached
        }
        return candidates.sorted {
            ($0.tmuxTarget ?? "") < ($1.tmuxTarget ?? "")
        }.first!
    }

    private func inferRootHint(from pane: TmuxShell.PaneDescriptor) -> String {
        let path = NSString(string: pane.currentPath).expandingTildeInPath
        if path.isEmpty { return "" }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        return basename.lowercased()
    }

    private func inferSessionType(from pane: TmuxShell.PaneDescriptor) -> String? {
        let title = pane.title.lowercased()
        let cmd = pane.currentCommand.lowercased()

        // 1. Explicit tproj-style role suffixes in pane title (highest confidence)
        //    e.g. "clawgate.cdx", "tproj.cc", "myapp.codex"
        if title.hasSuffix(".cdx") || title.hasSuffix(".codex")
            || title.contains(".cdx ") || title.contains(".codex ") {
            return "codex"
        }
        if title.hasSuffix(".cc") || title.hasSuffix(".claude")
            || title.contains(".cc ") || title.contains(".claude ") {
            return "claude_code"
        }

        // 2. Direct command match (running `claude` or `codex` binary)
        if cmd == "claude" || cmd.hasPrefix("claude-") { return "claude_code" }
        if cmd == "codex" || cmd.hasPrefix("codex-") { return "codex" }

        // 3. Fuzzy contains on title + cmd
        let haystackCmdTitle = [cmd, title].joined(separator: " ")
        if haystackCmdTitle.contains("codex") { return "codex" }
        if haystackCmdTitle.contains("claude") { return "claude_code" }

        // 4. Descendant process args probe (unresolved only, expensive)
        //    Walks the pane's process tree and checks for claude/codex binaries.
        //    This catches cases where Claude Code runs as "2.1.97" (version
        //    number as process name) or Codex runs as "node" (wrapper script).
        if pane.panePID > 0 {
            let args = TmuxShell.descendantProcessArgs(rootPID: pane.panePID, maxDepth: 3)
            for line in args {
                let lower = line.lowercased()
                // Check for explicit binary references
                if lower.contains("/codex") || lower.contains(" codex ") || lower.hasSuffix(" codex") {
                    return "codex"
                }
                if lower.contains("/claude") || lower.contains(" claude ") || lower.hasSuffix(" claude") {
                    return "claude_code"
                }
                // Check for CLI package references (node + claude-code / codex-cli)
                if lower.contains("@anthropic-ai/claude") || lower.contains("claude-code") {
                    return "claude_code"
                }
                if lower.contains("@openai/codex") || lower.contains("codex-cli") {
                    return "codex"
                }
            }
        }

        return nil
    }

    private func inferProject(from pane: TmuxShell.PaneDescriptor) -> String {
        // Prefer pane_current_path basename — it's the most stable project identifier
        // and matches how cc-status-bar reports projects (by repo root).
        let path = NSString(string: pane.currentPath).expandingTildeInPath
        let basename = URL(fileURLWithPath: path).lastPathComponent
        if !basename.isEmpty && basename != "/" { return basename }

        // Fall back to pane title, stripping known role suffixes (.cc, .cdx, etc.)
        let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title.lowercased() != pane.currentCommand.lowercased() {
            for suffix in [".cdx", ".cc", ".codex", ".claude"] {
                if title.lowercased().hasSuffix(suffix) {
                    return String(title.dropLast(suffix.count))
                }
            }
            return title
        }

        return pane.session
    }

    private enum PromptState: String {
        case running = "running"
        case waitingInput = "waiting_input"
    }

    private struct PromptClassification {
        let state: PromptState
        let lastPromptLine: String?
    }

    private func classifyPromptState(capture: String) -> PromptClassification {
        let tailLines = capture.components(separatedBy: "\n").suffix(30)

        for rawLine in tailLines.reversed() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.range(of: #"^• Working \("#, options: .regularExpression) != nil {
                return PromptClassification(state: .running, lastPromptLine: nil)
            }
        }

        for rawLine in tailLines.reversed() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if isIgnorableTailLine(trimmed) { continue }
            if trimmed.range(of: #"^[›❯>]\s*"#, options: .regularExpression) != nil {
                return PromptClassification(state: .waitingInput, lastPromptLine: trimmed)
            }
            return PromptClassification(state: .running, lastPromptLine: nil)
        }

        return PromptClassification(state: .running, lastPromptLine: nil)
    }

    private func isIgnorableTailLine(_ line: String) -> Bool {
        let patterns = [
            #"^Ran \d+ bash commands?$"#,
            #"^⏺ .*"#,
            #"^⎿ .*"#,
            #"^✻ .*"#,
            #"^✶ .*"#,
            #"^Tip: .*"#,
            #"^Crystallizing….*$"#,
            #"^thinking.*$"#,
            #"^⏵⏵ .*"#,
            #"^[-─]{3,}.*$"#,
            #"^╭.*╮$"#,
            #"^╰.*╯$"#,
            #"^│.*│$"#,
            #"^\[[^\]]+\].*$"#,
            #"^[CSW]: .*"#,
            #"^[^\s]+ (low|medium|high) · .*$"#,
            #"^gpt-[^\s]+ · .*$"#,
        ]

        for pattern in patterns {
            if line.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Detect permission prompt in the tail of pane output.
    ///
    /// Strategy (per Cdx):
    /// 1. Look only at the last 30 lines (not whole capture)
    /// 2. Require an anchored permission phrase
    /// 3. Require option markers nearby (yes/no, selector glyph, numbered list)
    private func detectPermissionPrompt(in capture: String?) -> Bool {
        guard let capture, !capture.isEmpty else { return false }

        // Tail window: last 30 lines
        let allLines = capture.components(separatedBy: "\n")
        let tail = allLines.suffix(30).joined(separator: "\n").lowercased()

        // Anchored permission phrases
        let permissionPatterns = [
            #"allow\s.*\?"#,
            #"do you want to allow"#,
            #"do you want to proceed"#,
            #"approve.*(command|tool|action)"#,
            #"permission.*(required|needed)"#,
            #"tool call.*\?"#,
        ]
        var matchedPhrase = false
        for pattern in permissionPatterns {
            if tail.range(of: pattern, options: .regularExpression) != nil {
                matchedPhrase = true
                break
            }
        }
        guard matchedPhrase else { return false }

        // Option markers: yes/no, selector glyphs, numbered list, "always allow"
        let optionPatterns = [
            #"\byes\b"#,
            #"\bno\b"#,
            #"always allow"#,
            #"don'?t ask again"#,
            #"[❯●○]"#,
            #"^\s*[1-9]\."#,
        ]
        for pattern in optionPatterns {
            if tail.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
}
