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
    private let nowProvider: () -> Date
    private var _isSending = false
    private var _lastSendAt: Date?

    init(windowSeconds: TimeInterval = 120.0, nowProvider: @escaping () -> Date = Date.init) {
        self.windowSeconds = windowSeconds
        self.nowProvider = nowProvider
    }

    func beginSending() { lock.lock(); _isSending = true; lock.unlock() }
    func endSending() { lock.lock(); _isSending = false; lock.unlock() }
    var isSending: Bool { lock.lock(); defer { lock.unlock() }; return _isSending }
    var lastSendAt: Date? { lock.lock(); defer { lock.unlock() }; return _lastSendAt }

    func recordSend(conversation: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        purgeStale()
        let now = nowProvider()
        entries.append((conversation: conversation, text: text, timestamp: now))
        _lastSendAt = now
    }

    func sentWithin(seconds: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purgeStale()
        guard let lastSendAt = _lastSendAt else { return false }
        return nowProvider().timeIntervalSince(lastSendAt) < seconds
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
        let cutoff = nowProvider().addingTimeInterval(-windowSeconds)
        entries.removeAll { $0.timestamp < cutoff }
        if let last = entries.last?.timestamp {
            _lastSendAt = last
        } else {
            _lastSendAt = nil
        }
    }
}
