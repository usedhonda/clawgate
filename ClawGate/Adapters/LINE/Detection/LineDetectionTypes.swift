import Foundation

struct LineDetectionSignal {
    let name: String
    let score: Int
    let text: String
    let conversation: String
    let details: [String: String]
}

struct LineDetectionDecision {
    let shouldEmit: Bool
    let eventType: String
    let confidence: String
    let score: Int
    let text: String
    let conversation: String
    let signals: [String]
    let details: [String: String]
}

struct LineDetectionStateSnapshot: Codable {
    let mode: String
    let threshold: Int
    let baselineCaptured: Bool
    let lastRowCount: Int
    let lastImageHash: UInt64
    let lastOCRText: String
    let lastSignals: [String]
    let lastScore: Int
    let lastConfidence: String
    let timestamp: String
}
