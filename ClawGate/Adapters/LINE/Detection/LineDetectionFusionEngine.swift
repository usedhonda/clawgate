import Foundation

struct LineDetectionFusionEngine {
    let threshold: Int

    func decide(
        signals: [LineDetectionSignal],
        fallbackText: String,
        fallbackConversation: String,
        isEcho: Bool
    ) -> LineDetectionDecision {
        guard !signals.isEmpty else {
            return LineDetectionDecision(
                shouldEmit: false,
                eventType: isEcho ? "echo_message" : "inbound_message",
                confidence: "low",
                score: 0,
                text: fallbackText,
                conversation: fallbackConversation,
                signals: [],
                details: [:]
            )
        }

        let score = min(100, signals.reduce(0) { $0 + max(0, $1.score) })
        let confidence: String
        if score >= 80 {
            confidence = "high"
        } else if score >= 50 {
            confidence = "medium"
        } else {
            confidence = "low"
        }

        let chosenText = signals.first(where: { !$0.text.isEmpty })?.text ?? fallbackText
        let chosenConversation = signals.first(where: { !$0.conversation.isEmpty })?.conversation ?? fallbackConversation

        var mergedDetails: [String: String] = [:]
        for signal in signals {
            for (k, v) in signal.details {
                mergedDetails[k] = v
            }
        }

        return LineDetectionDecision(
            shouldEmit: score >= threshold,
            eventType: isEcho ? "echo_message" : "inbound_message",
            confidence: confidence,
            score: score,
            text: chosenText,
            conversation: chosenConversation,
            signals: signals.map(\.name),
            details: mergedDetails
        )
    }
}
