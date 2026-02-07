import Foundation

/// Tracks recent send_message calls to enable echo suppression.
/// Thread-safe via NSLock.
///
/// NOTE: LINE Qt always reports window title as "LINE" (not the conversation name),
/// so echo matching is done at the adapter level (any recent send = likely echo).
final class RecentSendTracker {
    private let lock = NSLock()
    private var entries: [(conversation: String, text: String, timestamp: Date)] = []
    private let windowSeconds: TimeInterval = 8.0

    /// Record that a message was just sent to the given conversation.
    func recordSend(conversation: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        purgeStale()
        entries.append((conversation: conversation, text: text, timestamp: Date()))
    }

    /// Returns true if any send was recorded within the temporal window.
    /// Conversation name is ignored because LINE Qt window title is always "LINE".
    func isLikelyEcho() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purgeStale()
        return !entries.isEmpty
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
