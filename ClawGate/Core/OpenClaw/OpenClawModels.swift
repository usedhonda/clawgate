import Foundation
import CryptoKit

extension Notification.Name {
    static let petBubbleNotify = Notification.Name("petBubbleNotify")
    /// Posted by PetModel when user requests Chrome page capture → AppRuntime publishes to EventBus.
    static let petChromeCaptureFired = Notification.Name("petChromeCaptureFired")
}

// MARK: - Events from Gateway

/// Events received from OpenClaw WebSocket
enum OpenClawEvent {
    case connected(sessionId: String, sessionKey: String)
    case message(OpenClawChatMessage)
    case delta(messageId: String, text: String)
    case messageComplete(messageId: String)
    case history([OpenClawChatMessage])
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
    var isProactive: Bool

    enum Role: String {
        case user
        case assistant
    }

    init(id: String = UUID().uuidString, role: Role, text: String,
         timestamp: Date = Date(), isStreaming: Bool = false, isProactive: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isProactive = isProactive
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

// MARK: - Device Identity (file-based for dev, Keychain for release)

struct OpenClawDeviceIdentity {
    let deviceId: String
    let publicKeyRawBase64URL: String
    private let privateKey: Curve25519.Signing.PrivateKey

    func signPayload(_ payload: String) throws -> String {
        let signature = try privateKey.signature(for: Data(payload.utf8))
        return Data(signature).base64URLEncoded()
    }

    private static var cached: OpenClawDeviceIdentity?

    /// File path for dev identity storage (no Keychain dialog)
    private static var identityFilePath: String {
        NSString("~/.clawgate/device-identity.json").expandingTildeInPath
    }

    /// Load from cache → file → Keychain → create new
    static func loadOrCreate() throws -> OpenClawDeviceIdentity {
        if let cached { return cached }

        // 1. Try file backend (dev-friendly, no dialog)
        if let raw = loadFromFile() {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            let identity = makeIdentity(from: key)
            cached = identity
            return identity
        }

        // 2. Try Keychain (may trigger dialog on unsigned builds)
        if let raw = try? keychainLoad() {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            let identity = makeIdentity(from: key)
            // Migrate to file so we don't hit Keychain again
            saveToFile(raw)
            cached = identity
            return identity
        }

        // 3. Generate new key, save to file
        let key = Curve25519.Signing.PrivateKey()
        saveToFile(key.rawRepresentation)
        let identity = makeIdentity(from: key)
        cached = identity
        return identity
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

    // MARK: - File Backend

    private static func loadFromFile() -> Data? {
        guard let data = FileManager.default.contents(atPath: identityFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["privateKeyRawBase64URL"] as? String,
              let raw = Data(base64URLDecoded: b64) else {
            return nil
        }
        return raw
    }

    private static func saveToFile(_ raw: Data) {
        let json: [String: Any] = [
            "version": 1,
            "privateKeyRawBase64URL": raw.base64URLEncoded()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
        let dir = (identityFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: identityFilePath, contents: data, attributes: [.posixPermissions: 0o600])
    }

    // MARK: - Keychain Backend (fallback)

    private static func keychainLoad() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.clawgate.openclaw.device",
            kSecAttrAccount as String: "gateway-client-ed25519",
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw OpenClawError.connectionFailed("Keychain load failed: \(status)")
        }
        return data
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

    init?(base64URLDecoded str: String) {
        var b64 = str
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        self.init(base64Encoded: b64)
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

struct ChatHistoryParams: Encodable {
    let sessionKey: String
    let limit: Int
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
    let messages: [HistoryMessage]?
}

struct HistoryMessage: Decodable {
    let id: String?
    let role: String?
    let text: String?
    let content: [ChatContentPayload]?
    let createdAt: String?
    let timestamp: String?
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
