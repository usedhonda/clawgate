import Foundation
import CryptoKit

// MARK: - Events from Gateway

/// Events received from OpenClaw WebSocket
enum OpenClawEvent {
    case connected(sessionId: String, sessionKey: String)
    case message(OpenClawChatMessage)
    case delta(messageId: String, text: String)
    case messageComplete(messageId: String)
    case error(OpenClawError)
    case disconnected(reason: String?)
}

/// Chat message for pet bubble display
struct OpenClawChatMessage: Identifiable, Equatable {
    let id: String
    let role: Role
    var text: String
    let timestamp: Date
    var isStreaming: Bool

    enum Role: String {
        case user
        case assistant
    }

    init(id: String = UUID().uuidString, role: Role, text: String,
         timestamp: Date = Date(), isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }
}

/// OpenClaw error types
enum OpenClawError: Error {
    case connectionFailed(String)
    case authenticationFailed
    case serverError(code: String, message: String)
    case timeout
    case unknown(String)
}

// MARK: - Device Identity (macOS Keychain)

struct OpenClawDeviceIdentity {
    let deviceId: String
    let publicKeyRawBase64URL: String
    private let privateKey: Curve25519.Signing.PrivateKey

    func signPayload(_ payload: String) throws -> String {
        let signature = try privateKey.signature(for: Data(payload.utf8))
        return Data(signature).base64URLEncoded()
    }

    /// Load from Keychain or create new identity
    static func loadOrCreate() throws -> OpenClawDeviceIdentity {
        let service = "com.clawgate.openclaw.device"
        let account = "gateway-client-ed25519"

        // Try loading existing key from Keychain
        if let existing = try? keychainLoad(service: service, account: account) {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: existing)
            return makeIdentity(from: key)
        }

        // Generate new key
        let key = Curve25519.Signing.PrivateKey()
        try keychainSave(key.rawRepresentation, service: service, account: account)
        return makeIdentity(from: key)
    }

    private static func makeIdentity(from key: Curve25519.Signing.PrivateKey) -> OpenClawDeviceIdentity {
        let pubRaw = key.publicKey.rawRepresentation
        let deviceId = SHA256.hash(data: pubRaw).compactMap { String(format: "%02x", $0) }.joined()
        return OpenClawDeviceIdentity(
            deviceId: deviceId,
            publicKeyRawBase64URL: pubRaw.base64URLEncoded(),
            privateKey: key
        )
    }

    private static func keychainLoad(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw OpenClawError.connectionFailed("Keychain load failed: \(status)")
        }
        return data
    }

    private static func keychainSave(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw OpenClawError.connectionFailed("Keychain save failed: \(status)")
        }
    }
}

// MARK: - Base64URL

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Gateway Protocol Types (Outgoing)

struct ConnectRequest: Encodable {
    let type: String
    let id: String
    let method: String
    let params: ConnectParams
}

struct ConnectParams: Encodable {
    let minProtocol: Int
    let maxProtocol: Int
    let client: ClientInfo
    let role: String
    let scopes: [String]
    let auth: AuthParams
    let locale: String
    let userAgent: String
    let device: ConnectDeviceParams?
}

struct ClientInfo: Encodable {
    let id: String
    let version: String
    let platform: String
    let mode: String
}

struct AuthParams: Encodable {
    let token: String
}

struct ConnectDeviceParams: Encodable {
    let id: String
    let publicKey: String
    let signature: String
    let signedAt: Int64
    let nonce: String?
}

struct GatewayRequest<T: Encodable>: Encodable {
    let type: String
    let id: String
    let method: String
    let params: T
}

struct ChatSendParams: Encodable {
    let sessionKey: String
    let message: String
    let idempotencyKey: String
}

struct SessionSubscribeParams: Encodable {
    let key: String
}

// MARK: - Gateway Protocol Types (Incoming)

struct IncomingMessage: Decodable {
    let type: String
    let event: String?
    let payload: IncomingPayload?
    let error: IncomingError?
    let id: String?
    let ok: Bool?
}

struct IncomingPayload: Decodable {
    let type: String?
    let `protocol`: Int?
    let snapshot: SnapshotPayload?
    let nonce: String?
    let sessionId: String?
    let sessionKey: String?
    let runId: String?
    let stream: String?
    let data: AgentDataPayload?
    let state: String?
    let message: ChatMessagePayload?
    let messageId: String?
    let content: String?
    let delta: String?
}

struct AgentDataPayload: Decodable {
    let delta: String?
}

struct ChatMessagePayload: Decodable {
    let role: String?
    let content: [ChatContentPayload]?
}

struct ChatContentPayload: Decodable {
    let type: String?
    let text: String?
}

struct SnapshotPayload: Decodable {
    let sessionDefaults: SessionDefaultsPayload?
}

struct SessionDefaultsPayload: Decodable {
    let mainSessionKey: String?
}

struct IncomingError: Decodable {
    let code: String
    let message: String
}
