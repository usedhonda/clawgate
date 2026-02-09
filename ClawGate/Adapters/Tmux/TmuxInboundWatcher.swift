import Foundation

/// Watches for Claude Code task completion by monitoring CCStatusBarClient state changes.
/// When a session transitions from "running" to "waiting_input", captures the pane output
/// and emits an inbound_message event on the EventBus.
final class TmuxInboundWatcher {

    private let ccClient: CCStatusBarClient
    private let eventBus: EventBus
    private let logger: AppLogger
    private let configStore: ConfigStore

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
        logger.log(.info, "TmuxInboundWatcher: started")
    }

    func stop() {
        ccClient.onStateChange = nil
        logger.log(.info, "TmuxInboundWatcher: stopped")
    }

    private func handleStateChange(session: CCStatusBarClient.CCSession,
                                   oldStatus: String, newStatus: String) {
        // Only care about running -> waiting_input (task completion)
        guard oldStatus == "running" && newStatus == "waiting_input" else { return }

        // Check session mode — ignore sessions are skipped
        let config = configStore.load()
        let mode = config.tmuxSessionModes[session.project] ?? "ignore"
        guard mode == "observe" || mode == "autonomous" else {
            logger.log(.debug, "TmuxInboundWatcher: ignoring \(session.project) (mode=ignore)")
            return
        }

        logger.log(.info, "TmuxInboundWatcher: completion detected for \(session.project) (mode=\(mode))")

        // Capture pane output on background queue
        BlockingWork.queue.async { [weak self] in
            self?.captureAndEmit(session: session, mode: mode)
        }
    }

    private func captureAndEmit(session: CCStatusBarClient.CCSession, mode: String) {
        guard let target = session.tmuxTarget else {
            logger.log(.warning, "TmuxInboundWatcher: no tmux target for \(session.project)")
            return
        }

        var outputSummary: String
        do {
            let rawOutput = try TmuxShell.capturePane(target: target, lines: 30)
            outputSummary = extractSummary(from: rawOutput)
        } catch {
            logger.log(.warning, "TmuxInboundWatcher: capture-pane failed for \(target): \(error)")
            outputSummary = "(capture failed)"
        }

        let payload: [String: String] = [
            "conversation": session.project,
            "text": outputSummary,
            "source": "completion",
            "project": session.project,
            "tmux_target": target,
            "sender": "claude_code",
            "mode": mode,
        ]

        _ = eventBus.append(type: "inbound_message", adapter: "tmux", payload: payload)
        logger.log(.info, "TmuxInboundWatcher: emitted completion event for \(session.project) (mode=\(mode))")
    }

    /// Extract a meaningful summary from captured pane output.
    /// Looks for key patterns like cost/duration lines, removes blank lines, trims.
    private func extractSummary(from output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Look for interesting patterns from the end
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
            if summaryLines.filter({ !$0.isEmpty }).count >= 15 { break }
        }

        let summary = summaryLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate if too long (keep last part which is more relevant)
        if summary.count > 1000 {
            return String(summary.suffix(1000))
        }
        return summary
    }
}
