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

struct HTTPResult {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let body: Data
}
