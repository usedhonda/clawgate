import Foundation
import NIOHTTP1

struct SendPayload: Codable {
    let conversationHint: String
    let text: String
    let enterToSend: Bool

    enum CodingKeys: String, CodingKey {
        case conversationHint = "conversation_hint"
        case text
        case enterToSend = "enter_to_send"
    }
}

struct SendRequest: Codable {
    let adapter: String
    let action: String
    let payload: SendPayload
}

struct SendResult: Codable {
    let adapter: String
    let action: String
    let messageID: String
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case adapter
        case action
        case messageID = "message_id"
        case timestamp
    }
}

struct ErrorPayload: Codable {
    let code: String
    let message: String
    let retriable: Bool
    let failedStep: String?
    let details: String?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case retriable
        case failedStep = "failed_step"
        case details
    }
}

struct APIResponse<T: Codable>: Codable {
    let ok: Bool
    let result: T?
    let error: ErrorPayload?
}

struct HealthResponse: Codable {
    let ok: Bool
    let version: String
}

struct PollResponse: Codable {
    let ok: Bool
    let events: [BridgeEvent]
    let nextCursor: Int64

    enum CodingKeys: String, CodingKey {
        case ok
        case events
        case nextCursor = "next_cursor"
    }
}

struct ConversationContext: Codable {
    let adapter: String
    let conversationName: String?
    let hasInputField: Bool
    let windowTitle: String?
    let timestamp: String
    enum CodingKeys: String, CodingKey {
        case adapter
        case conversationName = "conversation_name"
        case hasInputField = "has_input_field"
        case windowTitle = "window_title"
        case timestamp
    }
}

struct VisibleMessage: Codable {
    let text: String
    let sender: String      // "self" | "other" | "unknown"
    let yOrder: Int
    enum CodingKeys: String, CodingKey {
        case text, sender
        case yOrder = "y_order"
    }
}

struct MessageList: Codable {
    let adapter: String
    let conversationName: String?
    let messages: [VisibleMessage]
    let messageCount: Int
    let timestamp: String
    enum CodingKeys: String, CodingKey {
        case adapter
        case conversationName = "conversation_name"
        case messages
        case messageCount = "message_count"
        case timestamp
    }
}

struct ConversationEntry: Codable {
    let name: String
    let yOrder: Int
    let hasUnread: Bool
    enum CodingKeys: String, CodingKey {
        case name
        case yOrder = "y_order"
        case hasUnread = "has_unread"
    }
}

struct ConversationList: Codable {
    let adapter: String
    let conversations: [ConversationEntry]
    let count: Int
    let timestamp: String
}

struct HTTPResult {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let body: Data
}

// MARK: - Doctor Report

struct DoctorCheck: Codable {
    let name: String
    let status: String          // "ok", "warning", "error"
    let message: String
    let details: String?
}

struct DoctorReport: Codable {
    let ok: Bool
    let version: String
    let checks: [DoctorCheck]
    let summary: DoctorSummary
    let timestamp: String
}

struct DoctorSummary: Codable {
    let total: Int
    let passed: Int
    let warnings: Int
    let errors: Int
}

// MARK: - Config Response

struct ConfigGeneralSection: Codable {
    let debugLogging: Bool
    let includeMessageBodyInLogs: Bool
}

struct ConfigLineSection: Codable {
    let defaultConversation: String
    let pollIntervalSeconds: Int
    let detectionMode: String
    let fusionThreshold: Int
    let enablePixelSignal: Bool
    let enableProcessSignal: Bool
    let enableNotificationStoreSignal: Bool

    enum CodingKeys: String, CodingKey {
        case defaultConversation = "default_conversation"
        case pollIntervalSeconds = "poll_interval_seconds"
        case detectionMode = "detection_mode"
        case fusionThreshold = "fusion_threshold"
        case enablePixelSignal = "enable_pixel_signal"
        case enableProcessSignal = "enable_process_signal"
        case enableNotificationStoreSignal = "enable_notification_store_signal"
    }
}

struct ConfigTmuxSection: Codable {
    let enabled: Bool
    let statusBarUrl: String
    let sessionModes: [String: String]  // project -> "observe" | "auto" | "autonomous"
}

struct ConfigResult: Codable {
    let version: String
    let general: ConfigGeneralSection
    let line: ConfigLineSection
    let tmux: ConfigTmuxSection
}

// MARK: - Stats Response

struct DayStatsEntry: Codable {
    let date: String
    let stats: DayStats
}

struct StatsResult: Codable {
    let today: DayStats
    let history: [DayStatsEntry]
    let totalDaysTracked: Int

    enum CodingKeys: String, CodingKey {
        case today
        case history
        case totalDaysTracked = "total_days_tracked"
    }
}
