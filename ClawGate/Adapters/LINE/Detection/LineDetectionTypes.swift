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
    let lastCompletedPollAt: String
    let lastAcceptedAt: String
    let isPolling: Bool
    let consecutiveTimeouts: Int
    let skippedPollCount: Int
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case mode
        case threshold
        case baselineCaptured = "baseline_captured"
        case lastRowCount = "last_row_count"
        case lastImageHash = "last_image_hash"
        case lastOCRText = "last_ocr_text"
        case lastSignals = "last_signals"
        case lastScore = "last_score"
        case lastConfidence = "last_confidence"
        case lastCompletedPollAt = "last_completed_poll_at"
        case lastAcceptedAt = "last_accepted_at"
        case isPolling = "is_polling"
        case consecutiveTimeouts = "consecutive_timeouts"
        case skippedPollCount = "skipped_poll_count"
        case timestamp
    }
}

struct LineSurfaceHealthSnapshot: Codable {
    let conversation: String
    let hasSearchField: Bool
    let searchFieldValue: String
    let hasMessageInput: Bool
    let hasGreenSignal: Bool
    let hasTextSignal: Bool
    let matchesExpectedConversation: Bool
    let windowTitle: String?
    let reason: String
    let abnormal: Bool
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case conversation
        case hasSearchField = "has_search_field"
        case searchFieldValue = "search_field_value"
        case hasMessageInput = "has_message_input"
        case hasGreenSignal = "has_green_signal"
        case hasTextSignal = "has_text_signal"
        case matchesExpectedConversation = "matches_expected_conversation"
        case windowTitle = "window_title"
        case reason
        case abnormal
        case timestamp
    }
}

struct LineCaretakerSnapshot: Codable {
    let lastProbeAt: String
    let lastAssessmentReason: String
    let lastRepairAt: String
    let lastRepairReason: String
    let lastRepairSucceeded: Bool?
    let nextForcedRepairDueAt: String
    let cooldownUntil: String
    let lastSurface: LineSurfaceHealthSnapshot?
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case lastProbeAt = "last_probe_at"
        case lastAssessmentReason = "last_assessment_reason"
        case lastRepairAt = "last_repair_at"
        case lastRepairReason = "last_repair_reason"
        case lastRepairSucceeded = "last_repair_succeeded"
        case nextForcedRepairDueAt = "next_forced_repair_due_at"
        case cooldownUntil = "cooldown_until"
        case lastSurface = "last_surface"
        case timestamp
    }
}

struct LineHealthDebugSnapshot: Codable {
    let watcher: LineDetectionStateSnapshot?
    let caretaker: LineCaretakerSnapshot?
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
