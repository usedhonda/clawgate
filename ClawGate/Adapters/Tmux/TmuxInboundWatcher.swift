import Foundation

/// Watches for Claude Code task completion by monitoring CCStatusBarClient state changes.
/// When a session transitions from "running" to "waiting_input", captures the pane output
/// and emits an inbound_message event on the EventBus.
///
/// Distinguishes between two event types:
/// - `source: "completion"` — task completed, Claude Code is idle
/// - `source: "question"` — AskUserQuestion displayed, includes structured question data
final class TmuxInboundWatcher {

    /// Parsed question from capture-pane output.
    struct DetectedQuestion {
        let questionText: String
        let options: [String]
        let selectedIndex: Int
        let questionID: String
    }

    private let ccClient: CCStatusBarClient
    private let eventBus: EventBus
    private let logger: AppLogger
    private let configStore: ConfigStore

    // Progress timer — fallback emits running session output periodically (60s, cc-status-bar sends at 20s)
    private var progressTimer: DispatchSourceTimer?
    private var lastProgressHash: [String: Int] = [:]
    private var lastProgressSummary: [String: String] = [:]
    private let progressInterval: TimeInterval = 60

    // State change dedup — prevent duplicate onStateChange fires from multiple CCStatusBarClient paths
    private var lastStateChangeTime: [String: Date] = [:]
    private let stateChangeDedupInterval: TimeInterval = 5.0

    // Completion emit dedup — suppress duplicate completion events with identical payload shortly after emit.
    private struct CompletionEmitState {
        let fingerprint: Int
        let emittedAt: Date
    }
    private var lastCompletionEmitState: [String: CompletionEmitState] = [:]
    private let completionEmitDedupInterval: TimeInterval = 8.0

    init(ccClient: CCStatusBarClient, eventBus: EventBus, logger: AppLogger, configStore: ConfigStore) {
        self.ccClient = ccClient
        self.eventBus = eventBus
        self.logger = logger
        self.configStore = configStore
    }

    func start() {
        ccClient.onStateChange = { [weak self] session, oldStatus, newStatus in
            self?.handleStateChange(session: session, oldStatus: oldStatus, newStatus: newStatus, source: "ws")
        }
        ccClient.onProgress = { [weak self] session in
            self?.handleProgress(session: session)
        }
        startProgressTimer()
        logger.log(.info, "TmuxInboundWatcher: started (ws only)")
    }

    func stop() {
        ccClient.onStateChange = nil
        ccClient.onProgress = nil
        stopProgressTimer()
        logger.log(.info, "TmuxInboundWatcher: stopped")
    }

    private func handleStateChange(session: CCStatusBarClient.CCSession,
                                   oldStatus: String, newStatus: String,
                                   source: String = "ws") {
        // Time-based dedup: suppress duplicate fires for the same project+status within 5 seconds
        let now = Date()
        let dedupKey = "\(session.project):\(newStatus)"
        if let lastFire = lastStateChangeTime[dedupKey],
           now.timeIntervalSince(lastFire) < stateChangeDedupInterval {
            logger.log(.debug, "TmuxInboundWatcher: dedup skip \(session.project) \(oldStatus)->\(newStatus)")
            return
        }
        lastStateChangeTime[dedupKey] = now

        logger.log(.info, "TmuxInboundWatcher: handleStateChange \(session.project) \(oldStatus) -> \(newStatus) source=\(source) waitingReason=\(session.waitingReason ?? "nil")")
        let scPath = "/tmp/clawgate-statechange.log"
        let scExisting = (try? String(contentsOfFile: scPath, encoding: .utf8)) ?? ""
        let modeKey = AppConfig.modeKey(sessionType: session.sessionType, project: session.project)
        let scLine = "\(Date()) handleStateChange \(session.project) \(oldStatus)->\(newStatus) source=\(source) mode=\(configStore.load().tmuxSessionModes[modeKey] ?? "nil") waitingReason=\(session.waitingReason ?? "nil") tmux=\(session.tmuxTarget ?? "nil")\n"
        try? (scExisting + scLine).write(toFile: scPath, atomically: true, encoding: .utf8)
        // Skip non-representative sessions: only the most-active session per project+type
        // triggers automation. Others are effectively ignored.
        guard isRepresentativeSession(session) else {
            debugLog("skip non-rep: \(session.project) id=\(session.id)")
            return
        }

        // Check session mode — ignore sessions are skipped
        let config = configStore.load()
        let mode = config.tmuxSessionModes[modeKey] ?? "ignore"

        // Bootstrap: synthetic state change from CCStatusBarClient startup.
        // Always go through captureAndEmit (skip permission auto-approve which may be stale).
        if oldStatus == "bootstrap" && newStatus == "waiting_input" {
            debugLog("bootstrap for \(session.project) mode=\(mode) waitingReason=\(session.waitingReason ?? "nil")")
            guard mode == "observe" || mode == "auto" || mode == "autonomous" else {
                debugLog("bootstrap SKIP \(session.project) (mode=\(mode))")
                return
            }
            BlockingWork.queue.async { [weak self] in
                Thread.sleep(forTimeInterval: 0.2)
                self?.captureAndEmit(session: session, mode: mode)
            }
            return
        }

        // AskUserQuestion — cc-status-bar sends structured question data with waitingReason="askUserQuestion"
        if newStatus == "waiting_input" && session.waitingReason == "askUserQuestion" {
            debugLog("askUserQuestion detected for \(session.project) mode=\(mode)")
            guard mode == "autonomous" || mode == "auto" || mode == "observe" else { return }
            // Build DetectedQuestion from structured WS data (no pane capture needed)
            if let text = session.questionText, let options = session.questionOptions, options.count >= 2 {
                let question = DetectedQuestion(
                    questionText: text,
                    options: options,
                    selectedIndex: session.questionSelected ?? 0,
                    questionID: "\(Int(Date().timeIntervalSince1970 * 1000))"
                )
                if mode == "auto" {
                    BlockingWork.queue.async { [weak self] in
                        self?.autoAnswerQuestion(session: session, question: question,
                                                 target: session.tmuxTarget ?? "")
                    }
                } else {
                    // observe / autonomous -> emit to agent with pane context
                    var questionContext: String? = nil
                    if let capture = session.paneCapture, !capture.isEmpty {
                        questionContext = extractQuestionContext(from: capture, questionText: text)
                    } else if let target = session.tmuxTarget {
                        if let raw = try? TmuxShell.capturePane(target: target, lines: 50) {
                            questionContext = extractQuestionContext(from: raw, questionText: text)
                        }
                    }
                    emitQuestionEvent(session: session, question: question, mode: mode, context: questionContext)
                }
            } else {
                // Structured data missing — fall through to captureAndEmit as fallback
                debugLog("askUserQuestion but no structured data, falling back to captureAndEmit")
                BlockingWork.queue.async { [weak self] in
                    Thread.sleep(forTimeInterval: 0.2)
                    self?.captureAndEmit(session: session, mode: mode)
                }
            }
            return
        }

        // Permission prompt handling — older cc-status-bar may still report AskUserQuestion
        // as "permission_prompt", so we detect questions first and route accordingly.
        if newStatus == "waiting_input" && session.waitingReason == "permission_prompt" {
            debugLog("permission_prompt detected for \(session.project) mode=\(mode)")
            guard mode == "autonomous" || mode == "auto" || mode == "observe" else { return }
            BlockingWork.queue.async { [weak self] in
                guard let self else { return }
                Thread.sleep(forTimeInterval: 0.2)
                // Get pane output (ws pane_capture -> direct capture fallback)
                var rawOutput: String?
                if let capture = session.paneCapture, !capture.isEmpty {
                    rawOutput = capture
                } else if let target = session.tmuxTarget {
                    rawOutput = try? TmuxShell.capturePane(target: target, lines: 50)
                }
                // Check if this is actually an AskUserQuestion
                if let output = rawOutput, let question = self.detectQuestion(from: output) {
                    self.debugLog("permission_prompt -> actually question (\(question.options.count) opts)")
                    if mode == "auto" {
                        self.autoAnswerQuestion(session: session, question: question,
                                                target: session.tmuxTarget ?? "")
                    } else {
                        // observe / autonomous -> emit to agent with pane context
                        let questionContext = self.extractQuestionContext(from: output, questionText: question.questionText)
                        self.emitQuestionEvent(session: session, question: question, mode: mode, context: questionContext)
                    }
                    return
                }
                // Real permission prompt
                // Codex has no askUserQuestion — all interactive prompts
                // (Plan mode, etc.) come through permission_prompt.
                // For observe/autonomous: emit to agent so it can decide.
                if session.sessionType == "codex" {
                    if mode == "observe" || mode == "autonomous" {
                        self.debugLog("permission_prompt -> codex \(mode), emitting to agent")
                        self.captureAndEmit(session: session, mode: mode)
                        return
                    }
                    // auto mode falls through to autoApprove below
                }
                if mode == "observe" {
                    self.debugLog("permission_prompt -> observe mode, skip auto-approve")
                    return
                }
                self.debugLog("permission_prompt -> autoApprove (y)")
                self.autoApprovePermission(session: session)
            }
            return
        }

        // Task completion or question: running -> waiting_input (but NOT permission prompt)
        guard oldStatus == "running" && newStatus == "waiting_input" else {
            logger.log(.debug, "TmuxInboundWatcher: skipping \(session.project) (guard: oldStatus=\(oldStatus), newStatus=\(newStatus))")
            return
        }

        guard mode == "observe" || mode == "auto" || mode == "autonomous" else {
            logger.log(.debug, "TmuxInboundWatcher: ignoring \(session.project) (mode=\(mode))")
            return
        }

        logger.log(.info, "TmuxInboundWatcher: state change detected for \(session.project) (mode=\(mode))")

        // Wait 200ms for UI to finish rendering (AskUserQuestion draws incrementally)
        BlockingWork.queue.async { [weak self] in
            Thread.sleep(forTimeInterval: 0.2)
            self?.captureAndEmit(session: session, mode: mode)
        }
    }

    private func autoApprovePermission(session: CCStatusBarClient.CCSession) {
        guard let target = session.tmuxTarget else { return }
        do {
            try TmuxShell.sendSpecialKey(target: target, key: "y")
            logger.log(.info, "TmuxInboundWatcher: auto-approved permission for \(session.project)")
        } catch {
            logger.log(.warning, "TmuxInboundWatcher: auto-approve failed: \(error)")
        }
    }

    /// Extract the pane content above the question line as context for the reviewer agent.
    /// Returns nil if no meaningful context is found.
    private func extractQuestionContext(from output: String, questionText: String) -> String? {
        let lines = output.components(separatedBy: "\n")
        let trimmedQ = questionText.trimmingCharacters(in: .whitespaces)
        // Bottom-up search for the question line
        var questionLineIndex: Int? = nil
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.contains(trimmedQ) || trimmed.hasSuffix(trimmedQ) {
                questionLineIndex = i
                break
            }
        }
        guard let qIdx = questionLineIndex, qIdx > 0 else { return nil }
        let context = Array(lines[0..<qIdx])
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.count > 10 else { return nil }
        return context
    }

    /// Emit a question event to the EventBus so the reviewer agent can receive it.
    /// Used from both the permission_prompt branch and captureAndEmit.
    private func emitQuestionEvent(session: CCStatusBarClient.CCSession, question: DetectedQuestion, mode: String, context: String? = nil) {
        let eventID = UUID().uuidString
        let traceID = "tmux-\(eventID)"
        let payload: [String: String] = [
            "conversation": session.project,
            "text": question.questionText,
            "source": "question",
            "project": session.project,
            "tmux_target": session.tmuxTarget ?? "",
            "sender": session.sessionType == "codex" ? "codex" : "claude_code",
            "mode": mode,
            "event_id": eventID,
            "trace_id": traceID,
            "session_type": session.sessionType,
            "question_text": question.questionText,
            "question_options": question.options.joined(separator: "\n"),
            "question_selected": String(question.selectedIndex),
            "question_id": question.questionID,
            "question_context": context ?? "",
            "attention_level": "\(session.attentionLevel)",
        ]
        _ = eventBus.append(type: "inbound_message", adapter: "tmux", payload: payload)
        logger.log(.info, "TmuxInboundWatcher: emitted question event for \(session.project) (\(question.options.count) options, context=\(context != nil ? "\(context!.count)ch" : "nil"))")
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        let timer = DispatchSource.makeTimerSource(queue: BlockingWork.queue)
        timer.schedule(deadline: .now() + progressInterval, repeating: progressInterval)
        timer.setEventHandler { [weak self] in
            self?.emitProgressForRunningSessions()
        }
        timer.resume()
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func emitProgressForRunningSessions() {
        let config = configStore.load()
        let sessions = ccClient.allSessions()

        for session in sessions {
            guard session.status == "running" else { continue }

            let modeKey = AppConfig.modeKey(sessionType: session.sessionType, project: session.project)
            let mode = config.tmuxSessionModes[modeKey] ?? "ignore"
            guard mode != "ignore" else { continue }

            guard let target = session.tmuxTarget else { continue }

            do {
                let rawOutput = try TmuxShell.capturePane(target: target, lines: 50)
                let hash = rawOutput.hashValue

                if let lastHash = lastProgressHash[session.project], lastHash == hash {
                    continue // No change
                }
                lastProgressHash[session.project] = hash

                let summary = extractSummary(from: rawOutput)
                if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lastProgressSummary[session.project] = summary
                }
                let eventID = UUID().uuidString
                let traceID = "tmux-\(eventID)"
                let payload: [String: String] = [
                    "conversation": session.project,
                    "text": summary,
                    "source": "progress",
                    "project": session.project,
                    "tmux_target": target,
                    "sender": session.sessionType == "codex" ? "codex" : "claude_code",
                    "mode": mode,
                    "event_id": eventID,
                    "trace_id": traceID,
                    "session_type": session.sessionType,
                    "attention_level": "\(session.attentionLevel)",
                ]

                _ = eventBus.append(type: "inbound_message", adapter: "tmux", payload: payload)
                logger.log(.debug, "TmuxInboundWatcher: emitted progress for \(session.project)")
            } catch {
                logger.log(.debug, "TmuxInboundWatcher: progress capture failed for \(session.project): \(error)")
            }
        }
    }

    // MARK: - Auto-Answer (auto mode)

    /// Answer a single question step, then check for follow-up wizard steps.
    /// Multi-step wizards (AskUserQuestion with tabs) keep the session in waiting_input
    /// without triggering a state change, so we retry after each answer.
    private func autoAnswerQuestion(session: CCStatusBarClient.CCSession,
                                    question: DetectedQuestion, target: String) {
        answerSingleQuestion(question: question, target: target, project: session.project)

        // Multi-step wizard retry: after answering, re-check for next step.
        // Max 10 steps to avoid infinite loops.
        for step in 1...10 {
            Thread.sleep(forTimeInterval: 1.5)
            do {
                let rawOutput = try TmuxShell.capturePane(target: target, lines: 50)
                if let nextQuestion = detectQuestion(from: rawOutput) {
                    debugLog("wizard step \(step): \(nextQuestion.options.count) opts")
                    answerSingleQuestion(question: nextQuestion, target: target, project: session.project)
                } else {
                    debugLog("wizard step \(step): no more questions")
                    break
                }
            } catch {
                debugLog("wizard step \(step): capture failed: \(error)")
                break
            }
        }
    }

    private func answerSingleQuestion(question: DetectedQuestion, target: String, project: String) {
        let keywords = ["(recommended)", "don't ask", "always", "yes", "ok", "proceed", "approve"]
        let keyDelay: TimeInterval = 0.05

        // Find best affirmative option (0-indexed)
        var bestIndex = 0
        for (i, option) in question.options.enumerated() {
            let lower = option.lowercased()
            if keywords.contains(where: { lower.contains($0) }) {
                bestIndex = i
                break
            }
        }

        let delta = bestIndex - question.selectedIndex
        do {
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
            try TmuxShell.sendSpecialKey(target: target, key: "Enter")
            debugLog("answered \(project): option[\(bestIndex)]=\(question.options[bestIndex])")
            logger.log(.info, "TmuxInboundWatcher: auto-answered for \(project): "
                        + "option[\(bestIndex)]=\(question.options[bestIndex])")
        } catch {
            logger.log(.warning, "TmuxInboundWatcher: auto-answer failed: \(error)")
        }
    }

    /// Returns true if this session is the most-active one for its (sessionType, project).
    /// Peers with higher status priority -> this session is NOT the representative -> return false.
    private func isRepresentativeSession(_ session: CCStatusBarClient.CCSession) -> Bool {
        let priority = ["running": 2, "waiting_input": 1]
        let selfPriority = priority[session.status] ?? 0
        let peers = ccClient.sessions(forProject: session.project)
            .filter { $0.sessionType == session.sessionType && $0.id != session.id }
        return !peers.contains { (priority[$0.status] ?? 0) > selfPriority }
    }

    private func debugLog(_ line: String) {
        let path = "/tmp/clawgate-captureAndEmit.log"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let entry = "\(Date()) \(line)\n"
        try? (existing + entry).write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Handle progress events from cc-status-bar WS (session.progress with pane_capture)
    private func handleProgress(session: CCStatusBarClient.CCSession) {
        let config = configStore.load()
        let mode = config.tmuxSessionModes[AppConfig.modeKey(sessionType: session.sessionType, project: session.project)] ?? "ignore"
        guard mode != "ignore" else { return }
        guard session.status == "running" else { return }
        guard let target = session.tmuxTarget else { return }

        // Use pane_capture from WS if available
        let rawOutput: String
        if let capture = session.paneCapture, !capture.isEmpty {
            rawOutput = capture
        } else {
            return  // No capture from cc-status-bar, skip
        }

        let hash = rawOutput.hashValue
        if let lastHash = lastProgressHash[session.project], lastHash == hash {
            return // No change
        }
        lastProgressHash[session.project] = hash

        let summary = extractSummary(from: rawOutput)
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastProgressSummary[session.project] = summary
        }
        let eventID = UUID().uuidString
        let traceID = "tmux-\(eventID)"
        let payload: [String: String] = [
            "conversation": session.project,
            "text": summary,
            "source": "progress",
            "project": session.project,
            "tmux_target": target,
            "sender": session.sessionType == "codex" ? "codex" : "claude_code",
            "mode": mode,
            "event_id": eventID,
            "trace_id": traceID,
            "session_type": session.sessionType,
            "attention_level": "\(session.attentionLevel)",
        ]

        _ = eventBus.append(type: "inbound_message", adapter: "tmux", payload: payload)
        logger.log(.debug, "TmuxInboundWatcher: emitted ws-progress for \(session.project)")
    }

    private func captureAndEmit(session: CCStatusBarClient.CCSession, mode: String) {
        debugLog("START project=\(session.project) mode=\(mode) tmuxTarget=\(session.tmuxTarget ?? "nil")")

        guard let target = session.tmuxTarget else {
            debugLog("BAIL: no tmux target")
            logger.log(.warning, "TmuxInboundWatcher: no tmux target for \(session.project)")
            return
        }

        var rawOutput: String
        if let capture = session.paneCapture, !capture.isEmpty {
            rawOutput = capture
            debugLog("using pane_capture from ws len=\(rawOutput.count)")
        } else {
            // Fallback: direct capture for older cc-status-bar
            do {
                rawOutput = try TmuxShell.capturePane(target: target, lines: 50)
                debugLog("capturePane OK len=\(rawOutput.count)")
            } catch {
                debugLog("capturePane FAILED: \(error)")
                logger.log(.warning, "TmuxInboundWatcher: capture-pane failed for \(target): \(error)")
                rawOutput = ""
            }
        }

        // Try to detect AskUserQuestion menu
        if let question = detectQuestion(from: rawOutput) {
            debugLog("question detected: \(question.options.count) options")
            // Auto mode: answer locally without sending to the reviewer agent
            if mode == "auto" {
                autoAnswerQuestion(session: session, question: question, target: target)
                return
            }

            // observe/autonomous: send to agent via EventBus with pane context
            let questionContext = extractQuestionContext(from: rawOutput, questionText: question.questionText)
            emitQuestionEvent(session: session, question: question, mode: mode, context: questionContext)
            return
        }

        // Normal completion.
        debugLog("no question detected, entering completion path")
        // If capture fails/empty at completion boundary, fallback to latest progress summary.
        var outputSummary = rawOutput.isEmpty ? "" : extractSummary(from: rawOutput)
        debugLog("extractSummary len=\(outputSummary.count) empty=\(outputSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
        let captureState: String
        if !outputSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureState = "pane"
        } else if let fallback = lastProgressSummary[session.project],
                  !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputSummary = fallback
            captureState = "progress_fallback"
        } else if mode == "auto" {
            // Auto mode: emit even when capture is empty (bootstrap / idle at prompt).
            // Reviewer agent will recognize idle state and send "continue".
            outputSummary = "(idle at prompt — no recent output captured)"
            captureState = "idle_bootstrap"
        } else {
            debugLog("BAIL: empty capture, no fallback, mode=\(mode)")
            logger.log(.warning, "TmuxInboundWatcher: capture failed for \(session.project), skipping emit")
            lastProgressHash.removeValue(forKey: session.project)
            lastProgressSummary.removeValue(forKey: session.project)
            return
        }

        debugLog("emitting completion: captureState=\(captureState) summaryLen=\(outputSummary.count)")

        let normalizedForDedup = outputSummary
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dedupFingerprint = "\(mode)|\(captureState)|\(String(normalizedForDedup.prefix(2000)))".hashValue
        let now = Date()
        if let last = lastCompletionEmitState[session.project],
           last.fingerprint == dedupFingerprint,
           now.timeIntervalSince(last.emittedAt) < completionEmitDedupInterval {
            debugLog("completion dedup skip project=\(session.project)")
            logger.log(.debug, "TmuxInboundWatcher: completion dedup skip for \(session.project)")
            return
        }
        lastCompletionEmitState[session.project] = CompletionEmitState(
            fingerprint: dedupFingerprint,
            emittedAt: now
        )

        let eventID = UUID().uuidString
        let traceID = "tmux-\(eventID)"
        let payload: [String: String] = [
            "conversation": session.project,
            "text": outputSummary,
            "source": "completion",
            "project": session.project,
            "tmux_target": target,
            "sender": session.sessionType == "codex" ? "codex" : "claude_code",
            "mode": mode,
            "capture": captureState,
            "waiting_reason": session.waitingReason ?? "",
            "event_id": eventID,
            "trace_id": traceID,
            "session_type": session.sessionType,
            "attention_level": "\(session.attentionLevel)",
        ]

        let event = eventBus.append(type: "inbound_message", adapter: "tmux", payload: payload)
        debugLog("eventBus.append OK eventID=\(event.id)")
        logger.log(.info, "TmuxInboundWatcher: emitted completion event for \(session.project) (mode=\(mode))")

        // Clear progress snapshots after completion emission.
        lastProgressHash.removeValue(forKey: session.project)
        lastProgressSummary.removeValue(forKey: session.project)
    }

    /// Detect an AskUserQuestion menu from captured pane output.
    ///
    /// Multi-layer detection:
    /// 1. Session is in `waiting_input` state (gate — already ensured by caller)
    /// 2. A line ending with `?` (the question text)
    /// 3. Option lines: `❯`/`●` (selected) + `○` (unselected), OR
    ///    `❯`/`●` (selected) + numbered lines `N. text` (Claude Code format)
    ///
    /// Returns nil if no question pattern is detected.
    func detectQuestion(from output: String) -> DetectedQuestion? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // AskUserQuestion renders in two known formats:
        //
        // Format A (bullet markers):            Format B (numbered, Claude Code):
        //   ? Question text?                      ? Question text?
        //     ❯ Option 1 (selected)               ❯ 1. Option 1 (selected)
        //     ○ Option 2                             2. Option 2
        //     ○ Option 3                             3. Option 3
        //                                          Enter to select · ↑/↓ · Esc

        // U+276F HEAVY RIGHT-POINTING ANGLE QUOTATION MARK ORNAMENT (❯)
        let selectorChar: Character = "\u{276F}"
        // Also detect ● (U+25CF) as alternative selected marker
        let bulletSelected: Character = "\u{25CF}"
        let bulletUnselected: Character = "\u{25CB}" // ○

        var optionLines: [(index: Int, text: String, isSelected: Bool)] = []
        var questionLineIndex: Int? = nil

        // --- Phase 1: Backward scan for marker-based options (❯/●/○) ---
        var i = lines.count - 1
        var foundOptions = false

        while i >= 0 {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            let hasSelector = trimmed.contains(selectorChar) || trimmed.contains(bulletSelected)
            let hasBullet = trimmed.contains(bulletUnselected)

            if hasSelector || hasBullet {
                var optText = trimmed
                for prefix in ["❯ ", "● ", "○ "] {
                    if optText.hasPrefix(prefix) {
                        optText = String(optText.dropFirst(prefix.count))
                        break
                    }
                }
                optionLines.insert((index: i, text: optText.trimmingCharacters(in: .whitespaces),
                                    isSelected: hasSelector), at: 0)
                foundOptions = true
                i -= 1
                continue
            }

            // Once we found marker options, scan upward for question line
            if foundOptions {
                if trimmed.isEmpty {
                    i -= 1
                    continue
                }
                if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") {
                    questionLineIndex = i
                }
                break
            }

            i -= 1
        }

        // --- Phase 2: If only 1 option found (selected line only, no ○ markers),
        //     scan forward from the ❯ line for numbered options (Claude Code format) ---
        if optionLines.count == 1, let selOption = optionLines.first {
            let numberedOptionRe = try! NSRegularExpression(pattern: #"^\d+\.\s+"#)

            for j in (selOption.index + 1)..<lines.count {
                let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                // Stop at footer line
                if trimmed.hasPrefix("Enter to select") || trimmed.hasPrefix("Esc to cancel") { break }
                // Detect numbered option line (e.g. "2. Option text")
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if numberedOptionRe.firstMatch(in: trimmed, range: range) != nil {
                    optionLines.append((index: j, text: trimmed, isSelected: false))
                }
                // Skip description lines (non-numbered, non-empty)
            }
        }

        // Validate: need at least 2 options and a question line
        guard optionLines.count >= 2, let qIdx = questionLineIndex else {
            return nil
        }

        let questionText = lines[qIdx].trimmingCharacters(in: .whitespaces)
        let options = optionLines.map(\.text)
        let selectedIndex = optionLines.firstIndex(where: \.isSelected) ?? 0

        let questionID = "\(Int(Date().timeIntervalSince1970 * 1000))"

        return DetectedQuestion(
            questionText: questionText,
            options: options,
            selectedIndex: selectedIndex,
            questionID: questionID
        )
    }

    /// Extract a meaningful summary from captured pane output.
    /// Looks for key patterns like cost/duration lines, removes blank lines, trims.
    func extractSummary(from output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Keep a wide tail window to avoid dropping long, meaningful completions.
        var summaryLines: [String] = []
        var blankCount = 0

        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                blankCount += 1
                if blankCount > 2 { continue } // Skip excessive blanks
            } else {
                blankCount = 0
            }
            summaryLines.insert(trimmed, at: 0)

            // Stop once we have enough lines
            if summaryLines.filter({ !$0.isEmpty }).count >= 120 { break }
        }

        let summary = summaryLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate if too long (keep last part which is more relevant)
        if summary.count > 12000 {
            return String(summary.suffix(12000))
        }
        return summary
    }
}
