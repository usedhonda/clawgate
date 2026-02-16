import Foundation

/// Tracks recent send_message calls to enable echo suppression.
/// Thread-safe via NSLock.
///
/// NOTE: LINE Qt always reports window title as "LINE" (not the conversation name),
/// so echo matching is done at the adapter level (any recent send = likely echo).
final class RecentSendTracker {
    private let lock = NSLock()
    private var entries: [(conversation: String, text: String, timestamp: Date)] = []
    private let windowSeconds: TimeInterval
    private var _isSending = false

    init(windowSeconds: TimeInterval = 120.0) {
        self.windowSeconds = windowSeconds
    }

    func beginSending() { lock.lock(); _isSending = true; lock.unlock() }
    func endSending() { lock.lock(); _isSending = false; lock.unlock() }
    var isSending: Bool { lock.lock(); defer { lock.unlock() }; return _isSending }

    func recordSend(conversation: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        purgeStale()
        entries.append((conversation: conversation, text: text, timestamp: Date()))
    }

    func isLikelyEcho() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purgeStale()
        return !entries.isEmpty
    }

    /// Returns true if an inbound candidate text likely matches recent sent text.
    /// Uses both temporal window and normalized text matching.
    func isLikelyEcho(text candidateText: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purgeStale()
        guard !entries.isEmpty else { return false }

        for entry in entries.reversed() {
            if LineTextSanitizer.textLikelyContainsSentText(candidate: candidateText, sentText: entry.text) {
                return true
            }
        }
        return false
    }

    /// Returns the most recently sent text (for OCR text matching).
    func recentSentText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        purgeStale()
        return entries.last?.text
    }

    private func purgeStale() {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        entries.removeAll { $0.timestamp < cutoff }
    }
}
