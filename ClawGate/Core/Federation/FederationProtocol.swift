import Foundation

struct FederationEnvelope<T: Codable>: Codable {
    let type: String
    let timestamp: String
    let payload: T
}

struct FederationHelloPayload: Codable {
    let version: String
    let capabilities: [String]
}

struct FederationCommandPayload: Codable {
    let id: String
    let method: String
    let path: String
    let headers: [String: String]
    let body: String?
}

struct FederationResponsePayload: Codable {
    let id: String
    let status: Int
    let headers: [String: String]
    let body: String
}

struct FederationEventPayload: Codable {
    let event: BridgeEvent
}

enum FederationMessage {
    static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
