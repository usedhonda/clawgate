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

struct LineInboundDedupSnapshot: Codable {
    struct PipelineEntry: Codable {
        let ts: String
        let result: String          // "suppressed" | "passed"
        let reason: String          // "content_memory" | "fingerprint_window" | "accepted"
        let matchedLineHead: String // suppress 時のマッチ行先頭 40 文字
        let conversation: String
        let textHead: String        // 判定対象テキスト先頭 40 文字
        let emitted: Bool

        enum CodingKeys: String, CodingKey {
            case ts
            case result
            case reason
            case matchedLineHead = "matched_line_head"
            case conversation
            case textHead = "text_head"
            case emitted
        }
    }

    let seenConversations: [String: Int]  // conversation -> seen line count
    let seenLinesTotal: Int
    let lastFingerprintHead: String       // 先頭 60 文字
    let lastAcceptedAt: String            // ISO8601（未受信なら "never"）
    let fingerprintWindowSec: Int
    let pipelineHistory: [PipelineEntry]  // 最新 20 件（新しい順）
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case seenConversations = "seen_conversations"
        case seenLinesTotal = "seen_lines_total"
        case lastFingerprintHead = "last_fingerprint_head"
        case lastAcceptedAt = "last_accepted_at"
        case fingerprintWindowSec = "fingerprint_window_sec"
        case pipelineHistory = "pipeline_history"
        case timestamp
    }
}
