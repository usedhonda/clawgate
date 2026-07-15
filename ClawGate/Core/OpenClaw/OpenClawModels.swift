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

struct HealthParams: Encodable {}

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
    let resolvedModel: String?
    let resolvedThinking: String?
    let degraded: Bool?
    let fallbackReason: String?
    let stream: String?
    let data: AgentDataPayload?
    let state: String?
    let message: ChatMessagePayload?
    let messageId: String?
    let content: String?
    let delta: String?
    let messages: [HistoryMessage]?
    /// ambient.ingest response: whether the Gateway latched the L1 state.
    let stateAccepted: Bool?
    /// ambient.ingest response: per-event receipts (eventId/status/dedup).
    let events: [AmbientEventReceipt]?
    let hasFallbackReason: Bool

    private enum CodingKeys: String, CodingKey {
        case type
        case `protocol`
        case snapshot
        case nonce
        case sessionId
        case sessionKey
        case runId
        case resolvedModel
        case resolvedThinking
        case degraded
        case fallbackReason
        case stream
        case data
        case state
        case message
        case messageId
        case content
        case delta
        case messages
        case stateAccepted
        case events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        `protocol` = try container.decodeIfPresent(Int.self, forKey: .protocol)
        snapshot = try container.decodeIfPresent(SnapshotPayload.self, forKey: .snapshot)
        nonce = try container.decodeIfPresent(String.self, forKey: .nonce)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        resolvedModel = try container.decodeIfPresent(String.self, forKey: .resolvedModel)
        resolvedThinking = try container.decodeIfPresent(String.self, forKey: .resolvedThinking)
        degraded = try container.decodeIfPresent(Bool.self, forKey: .degraded)
        fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
        stream = try container.decodeIfPresent(String.self, forKey: .stream)
        data = try container.decodeIfPresent(AgentDataPayload.self, forKey: .data)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        message = try container.decodeIfPresent(ChatMessagePayload.self, forKey: .message)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        delta = try container.decodeIfPresent(String.self, forKey: .delta)
        messages = try container.decodeIfPresent([HistoryMessage].self, forKey: .messages)
        stateAccepted = try container.decodeIfPresent(Bool.self, forKey: .stateAccepted)
        events = try container.decodeIfPresent([AmbientEventReceipt].self, forKey: .events)
        hasFallbackReason = container.contains(.fallbackReason)
    }
}

/// Per-event receipt in the ambient.ingest response payload.
struct AmbientEventReceipt: Decodable {
    let sourceEventId: String?
    let eventId: String?
    let status: String?
    let dedup: String?
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

enum PetLogDispatchAckValidationError: Error, Equatable {
    case missingField(String)
    case invalidThinking(String)
    case invalidModel(String)
    case unexpectedFallback
    case invalidFallbackReason(String)
}

/// Canonical validation result for `chat.send` ACK diagnostics for Pet Log.
/// The model must include exact fields and bounded values; malformed
/// dispatch metadata fails closed and surfaces through existing Log error path.
struct PetLogDispatchAck: Equatable {
    let runId: String
    let resolvedModel: String
    let resolvedThinking: String
    let degraded: Bool
    let fallbackReason: String?

    private static let fallbackPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,128}$")

    static func validate(from payload: IncomingPayload?) throws -> PetLogDispatchAck {
        guard let payload else {
            throw PetLogDispatchAckValidationError.missingField("payload")
        }
        guard let runId = payload.runId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runId.isEmpty else {
            throw PetLogDispatchAckValidationError.missingField("runId")
        }

        guard let model = payload.resolvedModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            throw PetLogDispatchAckValidationError.missingField("resolvedModel")
        }
        guard let thinking = payload.resolvedThinking?.trimmingCharacters(in: .whitespacesAndNewlines),
              !thinking.isEmpty else {
            throw PetLogDispatchAckValidationError.missingField("resolvedThinking")
        }
        guard thinking == "max" else {
            throw PetLogDispatchAckValidationError.invalidThinking(thinking)
        }
        guard let degraded = payload.degraded else {
            throw PetLogDispatchAckValidationError.missingField("degraded")
        }
        let fallbackReason = payload.fallbackReason?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch model {
        case "openai/gpt-5.6-sol":
            guard !degraded else {
                throw PetLogDispatchAckValidationError.invalidModel(model)
            }
            guard payload.hasFallbackReason else {
                throw PetLogDispatchAckValidationError.missingField("fallbackReason")
            }
            guard fallbackReason == nil else {
                throw PetLogDispatchAckValidationError.unexpectedFallback
            }
            return PetLogDispatchAck(
                runId: runId,
                resolvedModel: model,
                resolvedThinking: thinking,
                degraded: degraded,
                fallbackReason: nil
            )
        case "openai/gpt-5.6-terra":
            guard degraded else {
                throw PetLogDispatchAckValidationError.invalidModel(model)
            }
            guard payload.hasFallbackReason else {
                throw PetLogDispatchAckValidationError.missingField("fallbackReason")
            }
            guard let reason = fallbackReason else {
                throw PetLogDispatchAckValidationError.invalidFallbackReason("nil")
            }
            guard !reason.isEmpty,
                  reason.count <= 128,
                  Self.fallbackPattern.firstMatch(in: reason, range: NSRange(reason.startIndex..., in: reason)) != nil else {
                throw PetLogDispatchAckValidationError.invalidFallbackReason(reason)
            }
            return PetLogDispatchAck(
                runId: runId,
                resolvedModel: model,
                resolvedThinking: thinking,
                degraded: degraded,
                fallbackReason: reason
            )
        default:
            throw PetLogDispatchAckValidationError.invalidModel(model)
        }
    }
}
