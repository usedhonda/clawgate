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

    // Progress timer — emits running session output periodically
    private var progressTimer: DispatchSourceTimer?
    private var lastProgressHash: [String: Int] = [:]
    private var lastProgressSummary: [String: String] = [:]
    private let progressInterval: TimeInterval = 20

    init(ccClient: CCStatusBarClient, eventBus: EventBus, logger: AppLogger, configStore: ConfigStore) {
        self.ccClient = ccClient
        self.eventBus = eventBus
        self.logger = logger
        self.configStore = configStore
    }

    func start() {
        ccClient.onStateChange = { [weak self] session, oldStatus, newStatus in
            self?.handleStateChange(session: session, oldStatus: oldStatus, newStatus: newStatus)
        }
        startProgressTimer()
        logger.log(.info, "TmuxInboundWatcher: started")
    }

    func stop() {
        ccClient.onStateChange = nil
        stopProgressTimer()
        logger.log(.info, "TmuxInboundWatcher: stopped")
    }

    private func handleStateChange(session: CCStatusBarClient.CCSession,
                                   oldStatus: String, newStatus: String) {
        // Check session mode — ignore sessions are skipped
        let config = configStore.load()
        let mode = config.tmuxSessionModes[session.project] ?? "ignore"

        // Permission prompt auto-approval (autonomous only)
        if newStatus == "waiting_input" && session.waitingReason == "permission_prompt" {
            guard mode == "autonomous" || mode == "auto" else { return }
            BlockingWork.queue.async { [weak self] in
                self?.autoApprovePermission(session: session)
            }
            return
        }

        // Task completion or question: running -> waiting_input (but NOT permission prompt)
        guard oldStatus == "running" && newStatus == "waiting_input" else { return }

        guard mode == "observe" || mode == "auto" || mode == "autonomous" else {
            logger.log(.debug, "TmuxInboundWatcher: ignoring \(session.project) (mode=ignore)")
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

            let mode = config.tmuxSessionModes[session.project] ?? "ignore"
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
                let payload: [String: String] = [
                    "conversation": session.project,
                    "text": summary,
                    "source": "progress",
                    "project": session.project,
                    "tmux_target": target,
                    "sender": "claude_code",
                    "mode": mode,
                    "event_id": eventID,
                ]

                _ = eventBus.append(type: "inbound_message", adapter: "tmux", payload: payload)
                logger.log(.debug, "TmuxInboundWatcher: emitted progress for \(session.project)")
            } catch {
                logger.log(.debug, "TmuxInboundWatcher: progress capture failed for \(session.project): \(error)")
            }
        }
    }

    // MARK: - Auto-Answer (auto mode)

    private func autoAnswerQuestion(session: CCStatusBarClient.CCSession,
                                    question: DetectedQuestion, target: String) {
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
            logger.log(.info, "TmuxInboundWatcher: auto-answered for \(session.project): "
                        + "option[\(bestIndex)]=\(question.options[bestIndex])")
        } catch {
            logger.log(.warning, "TmuxInboundWatcher: auto-answer failed: \(error)")
        }
    }

    private func captureAndEmit(session: CCStatusBarClient.CCSession, mode: String) {
        guard let target = session.tmuxTarget else {
            logger.log(.warning, "TmuxInboundWatcher: no tmux target for \(session.project)")
            return
        }

        var rawOutput: String
        do {
            rawOutput = try TmuxShell.capturePane(target: target, lines: 50)
        } catch {
            logger.log(.warning, "TmuxInboundWatcher: capture-pane failed for \(target): \(error)")
            rawOutput = ""
        }

        // Try to detect AskUserQuestion menu
        if let question = detectQuestion(from: rawOutput) {
            // Auto mode: answer locally without sending to Chi
            if mode == "auto" {
                autoAnswerQuestion(session: session, question: question, target: target)
                return
            }

            // observe/autonomous: send to Chi via EventBus
            let eventID = UUID().uuidString
            let payload: [String: String] = [
                "conversation": session.project,
                "text": question.questionText,
                "source": "question",
                "project": session.project,
                "tmux_target": target,
                "sender": "claude_code",
                "mode": mode,
                "event_id": eventID,
                "question_text": question.questionText,
                "question_options": question.options.joined(separator: "\n"),
                "question_selected": String(question.selectedIndex),
                "question_id": question.questionID,
            ]

            _ = eventBus.append(type: "inbound_message", adapter: "tmux", payload: payload)
            logger.log(.info, "TmuxInboundWatcher: emitted question event for \(session.project) (\(question.options.count) options)")
            return
        }

        // Normal completion.
        // If capture fails/empty at completion boundary, fallback to latest progress summary.
        var outputSummary = rawOutput.isEmpty ? "" : extractSummary(from: rawOutput)
        let captureState: String
        if !outputSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureState = "pane"
        } else if let fallback = lastProgressSummary[session.project],
                  !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputSummary = fallback
            captureState = "progress_fallback"
        } else {
            logger.log(.warning, "TmuxInboundWatcher: capture failed for \(session.project), skipping emit")
            lastProgressHash.removeValue(forKey: session.project)
            lastProgressSummary.removeValue(forKey: session.project)
            return
        }

        let eventID = UUID().uuidString
        let payload: [String: String] = [
            "conversation": session.project,
            "text": outputSummary,
            "source": "completion",
            "project": session.project,
            "tmux_target": target,
            "sender": "claude_code",
            "mode": mode,
            "capture": captureState,
            "event_id": eventID,
        ]

        _ = eventBus.append(type: "inbound_message", adapter: "tmux", payload: payload)
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
