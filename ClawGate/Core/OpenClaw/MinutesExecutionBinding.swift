import Foundation
import CryptoKit

/// Shared LP8 request fingerprint. Strings are hashed as exact UTF-8, never
/// normalized, trimmed, JSON quoted or reconstructed from a later prompt.
enum MinutesRequestFingerprint {
    static let scheme = "openclaw-execution-request-v1"

    static func compute(_ request: MinutesExecutionSendParams) throws -> String {
        let components = request.sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 3, components[0] == "agent",
              components.allSatisfy({ !$0.isEmpty }),
              request.sessionKey.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !request.idempotencyKey.isEmpty else {
            throw MinutesExecutionTransportError.invalidRequest
        }
        var hash = SHA256()
        hash.update(data: Data((scheme + "\0").utf8))
        let fields = [request.sessionKey, request.idempotencyKey,
                      MinutesExecutionSendParams.model, MinutesExecutionSendParams.thinking,
                      "1", "1", "1", request.message]
        for field in fields {
            let count = field.utf8.count
            guard count <= Int(UInt32.max) else { throw MinutesExecutionTransportError.invalidRequest }
            var length = UInt32(count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: Data(field.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Immutable admission diagnostics, not evidence of actual provider completion.
struct MinutesExecutionBinding: Codable, Equatable {
    let version: Int
    let requestFingerprintScheme: String
    let requestFingerprint: String
    let resolvedModel: String
    let resolvedThinking: String
    let degraded: Bool
    let fallbackReason: String?
    let isolationApplied: Bool
    let nonprojectionApplied: Bool
    let retentionApplied: Bool

    enum CodingKeys: String, CodingKey {
        case version, requestFingerprintScheme, requestFingerprint, resolvedModel, resolvedThinking
        case degraded, fallbackReason, isolationApplied, nonprojectionApplied, retentionApplied
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        requestFingerprintScheme = try c.decode(String.self, forKey: .requestFingerprintScheme)
        requestFingerprint = try c.decode(String.self, forKey: .requestFingerprint)
        resolvedModel = try c.decode(String.self, forKey: .resolvedModel)
        resolvedThinking = try c.decode(String.self, forKey: .resolvedThinking)
        degraded = try c.decode(Bool.self, forKey: .degraded)
        guard c.contains(.fallbackReason) else { throw MinutesExecutionTransportError.bindingMismatch }
        fallbackReason = try c.decodeIfPresent(String.self, forKey: .fallbackReason)
        isolationApplied = try c.decode(Bool.self, forKey: .isolationApplied)
        nonprojectionApplied = try c.decode(Bool.self, forKey: .nonprojectionApplied)
        retentionApplied = try c.decode(Bool.self, forKey: .retentionApplied)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(requestFingerprintScheme, forKey: .requestFingerprintScheme)
        try c.encode(requestFingerprint, forKey: .requestFingerprint)
        try c.encode(resolvedModel, forKey: .resolvedModel)
        try c.encode(resolvedThinking, forKey: .resolvedThinking)
        try c.encode(degraded, forKey: .degraded)
        if let fallbackReason { try c.encode(fallbackReason, forKey: .fallbackReason) }
        else { try c.encodeNil(forKey: .fallbackReason) }
        try c.encode(isolationApplied, forKey: .isolationApplied)
        try c.encode(nonprojectionApplied, forKey: .nonprojectionApplied)
        try c.encode(retentionApplied, forKey: .retentionApplied)
    }

    func matches(_ request: MinutesExecutionSendParams) -> Bool {
        version == 1 && requestFingerprintScheme == MinutesRequestFingerprint.scheme &&
        requestFingerprint == (try? request.requestFingerprint()) &&
        resolvedModel == MinutesExecutionSendParams.model && resolvedThinking == MinutesExecutionSendParams.thinking &&
        !degraded && fallbackReason == nil && isolationApplied && nonprojectionApplied && retentionApplied
    }

    static func validate(_ payload: IncomingPayload?, expected: MinutesExecutionSendParams,
                         requireTopLevel: Bool = false) throws -> Self {
        guard let p = payload, p.sessionKey == expected.sessionKey, p.runId == expected.idempotencyKey,
              let b = p.executionBinding, b.matches(expected) else {
            throw MinutesExecutionTransportError.bindingMismatch
        }
        // Reads need not repeat the ACK fields. Any duplicate must match, even
        // if explicitly null or malformed (field presence is tracked separately).
        let duplicates: [(String, Bool)] = [
            ("resolvedModel", p.resolvedModel == b.resolvedModel),
            ("resolvedThinking", p.resolvedThinking == b.resolvedThinking),
            ("degraded", p.degraded == b.degraded),
            ("fallbackReason", p.hasFallbackReason && p.fallbackReason == b.fallbackReason),
            ("isolationApplied", p.isolationApplied == b.isolationApplied),
            ("nonprojectionApplied", p.nonprojectionApplied == b.nonprojectionApplied)]
        for (key, equal) in duplicates where requireTopLevel || p.minutesFieldNames.contains(key) {
            guard equal else { throw MinutesExecutionTransportError.bindingMismatch }
        }
        if p.minutesFieldNames.contains("retentionApplied"), p.retentionApplied != b.retentionApplied {
            throw MinutesExecutionTransportError.bindingMismatch
        }
        return b
    }
}
