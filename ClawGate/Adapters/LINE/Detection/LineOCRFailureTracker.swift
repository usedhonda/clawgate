import Foundation

/// Counts consecutive polls where the bubble detector found something to read
/// but recognition failed. A quiet chat (no bubbles) is a success, a transient
/// capture or detector hiccup is neutral, and any success clears the streak, so
/// only a persistent recogniser fault ever reaches the threshold.
struct LineOCRFailureTracker {
    /// Polls run about every 12s, so this is roughly two minutes of failures.
    static let faultThreshold = 10

    private(set) var streak = 0
    private(set) var reason = ""
    private(set) var since: Date?

    var isFaulted: Bool { streak >= Self.faultThreshold }

    mutating func recordSuccess() {
        streak = 0
        reason = ""
        since = nil
    }

    /// `reason` is `InboundBubbleOCR.RecognizeFailure.rawValue`. An uncertain
    /// detector is not "bubbles present but unreadable", and an empty reason
    /// carries no evidence, so neither moves the streak.
    mutating func recordFailure(reason: String, at date: Date) {
        guard !reason.isEmpty, reason != InboundBubbleOCR.RecognizeFailure.detectorUncertain.rawValue else { return }
        if streak == 0 { since = date }
        streak += 1
        self.reason = reason
    }
}
