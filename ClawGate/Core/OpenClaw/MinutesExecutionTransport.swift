import Foundation

/// Model selection for the existing sequential minutes route. Deliberately
/// independent of the not-yet-supported isolated execution flags below.
struct MinutesModelSendParams: Encodable {
    let sessionKey: String
    let message: String
    let idempotencyKey: String
    let model = MinutesExecutionSendParams.model
    let thinking = MinutesExecutionSendParams.thinking
}

enum MinutesModelAck {
    static func validate(_ payload: IncomingPayload?, expectedRunID: String) throws -> String {
        guard let p = payload, p.status == "started", p.runId == expectedRunID,
              !expectedRunID.isEmpty, p.hasFallbackReason else {
            throw MinutesExecutionTransportError.invalidAcknowledgement
        }
        guard p.resolvedModel == MinutesExecutionSendParams.model,
              p.resolvedThinking == MinutesExecutionSendParams.thinking,
              p.degraded == false, p.fallbackReason == nil else {
            throw MinutesExecutionTransportError.modelMismatch
        }
        return expectedRunID
    }
}

/// Dedicated minutes wire, not a replacement for ordinary chat or Pet Log.
/// The default-off pilot caller requires the Gateway activation checkpoint.
struct MinutesExecutionSendParams: Codable, Equatable {
    static let model = "openai/gpt-6.1-sol"
    static let thinking = "high"
    let sessionKey: String
    let message: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case sessionKey, message, idempotencyKey, model, thinking
        case requestLocalContext, nonprojection, retainTerminalResult
    }

    init(sessionKey: String, message: String, idempotencyKey: String) {
        self.sessionKey = sessionKey; self.message = message; self.idempotencyKey = idempotencyKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try c.decode(String.self, forKey: .sessionKey)
        message = try c.decode(String.self, forKey: .message)
        idempotencyKey = try c.decode(String.self, forKey: .idempotencyKey)
        guard try c.decode(String.self, forKey: .model) == Self.model,
              try c.decode(String.self, forKey: .thinking) == Self.thinking,
              try c.decode(Bool.self, forKey: .requestLocalContext),
              try c.decode(Bool.self, forKey: .nonprojection),
              try c.decode(Bool.self, forKey: .retainTerminalResult) else {
            throw MinutesExecutionTransportError.invalidRequest
        }
        _ = try requestFingerprint()
    }

    func requestFingerprint() throws -> String { try MinutesRequestFingerprint.compute(self) }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionKey, forKey: .sessionKey)
        try c.encode(message, forKey: .message)
        try c.encode(idempotencyKey, forKey: .idempotencyKey)
        try c.encode(Self.model, forKey: .model)
        try c.encode(Self.thinking, forKey: .thinking)
        try c.encode(true, forKey: .requestLocalContext)
        try c.encode(true, forKey: .nonprojection)
        try c.encode(true, forKey: .retainTerminalResult)
    }
}

struct MinutesResultGetParams: Encodable {
    let sessionKey: String
    let runId: String
}

/// Bounded fixed errors: never put prompts, answer bodies or wire values in logs.
enum MinutesExecutionTransportError: Error, Equatable {
    case invalidAcknowledgement, identityMismatch, modelMismatch, isolationNotApplied
    case invalidResult, invalidRequest, bindingMismatch
}

struct MinutesExecutionAck: Equatable {
    let sessionKey: String
    let runId: String
    let binding: MinutesExecutionBinding
    private init(sessionKey: String, runId: String, binding: MinutesExecutionBinding) {
        self.sessionKey = sessionKey; self.runId = runId; self.binding = binding
    }

    static func validate(_ payload: IncomingPayload?, expected: MinutesExecutionSendParams) throws -> Self {
        guard let p = payload, p.status == "started" || p.status == "pending",
              p.hasResultRetentionExpiresAt, p.resultRetentionExpiresAt == nil,
              !p.minutesFieldNames.contains("terminal") else {
            throw MinutesExecutionTransportError.invalidAcknowledgement
        }
        let binding = try MinutesExecutionBinding.validate(p, expected: expected, requireTopLevel: true)
        return Self(sessionKey: expected.sessionKey, runId: expected.idempotencyKey, binding: binding)
    }
}

/// A validated same-request result can reconcile an ACK lost in transit.
/// Only this parser creates the wrapper; a bare terminal is not admission proof.
struct MinutesExecutionRead: Equatable {
    let result: MinutesExecutionResult
    let binding: MinutesExecutionBinding?
    private init(result: MinutesExecutionResult, binding: MinutesExecutionBinding?) {
        self.result = result; self.binding = binding
    }
    static func validate(_ payload: IncomingPayload?, expected: MinutesExecutionSendParams) throws -> Self {
        if payload?.status == "notFound" {
            guard payload?.minutesFieldNames == ["status"] else { throw MinutesExecutionTransportError.invalidResult }
            return Self(result: .notFound, binding: nil)
        }
        let binding = try MinutesExecutionBinding.validate(payload, expected: expected)
        let result = try MinutesExecutionResult.validate(payload, expected: .init(
            sessionKey: expected.sessionKey, runId: expected.idempotencyKey))
        return Self(result: result, binding: binding)
    }
}

/// Canonical retained results. `unavailable` is NOT permission to re-generate.
enum MinutesExecutionResult: Equatable {
    case pending
    case answer(String)
    case failed(code: String, retriable: Bool)
    case aborted
    case expired
    case notFound

    fileprivate static func validate(_ payload: IncomingPayload?, expected: MinutesResultGetParams) throws -> Self {
        guard let p = payload, let status = p.status else {
            throw MinutesExecutionTransportError.invalidResult
        }
        // The server deliberately omits identity on a notFound response.
        if status == "notFound" {
            guard p.sessionKey == nil, p.runId == nil, p.minutesTerminal == nil else {
                throw MinutesExecutionTransportError.invalidResult
            }
            return .notFound
        }
        guard p.sessionKey == expected.sessionKey, p.runId == expected.runId,
              !expected.sessionKey.isEmpty, !expected.runId.isEmpty else {
            throw MinutesExecutionTransportError.identityMismatch
        }
        switch status {
        case "pending":
            guard p.hasResultRetentionExpiresAt, p.resultRetentionExpiresAt == nil,
                  !p.minutesFieldNames.contains("terminal") else { throw MinutesExecutionTransportError.invalidResult }
            return .pending
        case "expired":
            guard !p.minutesFieldNames.contains("resultRetentionExpiresAt"), !p.minutesFieldNames.contains("terminal") else { throw MinutesExecutionTransportError.invalidResult }
            return .expired
        case "terminal":
            guard p.resultRetentionIsSafeInteger, let expiry = p.resultRetentionEpoch, expiry.isFinite, expiry > 0, expiry <= 9_007_199_254_740_991, expiry.rounded(.towardZero) == expiry,
                  let terminal = p.minutesTerminal else { throw MinutesExecutionTransportError.invalidResult }
            switch terminal.kind {
            case "answer":
                guard let answer = terminal.answer, !answer.isEmpty,
                      terminal.code == nil, terminal.retriable == nil else {
                    throw MinutesExecutionTransportError.invalidResult
                }
                return .answer(answer)
            case "error":
                guard terminal.answer == nil, let code = terminal.code, !code.isEmpty, code.utf8.count <= 128,
                      code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                          (97...122).contains($0) || [45, 46, 95].contains($0) }),
                      let retry = terminal.retriable else { throw MinutesExecutionTransportError.invalidResult }
                return .failed(code: code, retriable: retry)
            case "aborted":
                guard terminal.answer == nil, terminal.code == nil, terminal.retriable == nil else {
                    throw MinutesExecutionTransportError.invalidResult
                }
                return .aborted
            default: throw MinutesExecutionTransportError.invalidResult
            }
        default: throw MinutesExecutionTransportError.invalidResult
        }
    }
}

struct MinutesTerminalPayload: Decodable {
    let kind: String
    let answer: String?
    let code: String?
    let retriable: Bool?
}

extension OpenClawWSClient {
    /// Explicit model selection, not an isolation fallback. Used only by the
    /// current sequential part/overview path until the separate activation gate.
    func sendMinutesAwaitingModelRunID(_ message: String, sessionKey: String,
                                       idempotencyKey: String) async throws -> String {
        let payload = try await request(method: "chat.send", params: MinutesModelSendParams(
            sessionKey: sessionKey, message: message, idempotencyKey: idempotencyKey))
        return try MinutesModelAck.validate(payload, expectedRunID: idempotencyKey)
    }

    /// The caller must durably reserve this key first. Never retry as chat.
    func sendMinutesExecution(_ params: MinutesExecutionSendParams) async throws -> MinutesExecutionAck {
        _ = try params.requestFingerprint()
        registerMinutesExecutionRunID(params.idempotencyKey)
        let payload = try await request(method: "chat.send", params: params)
        return try MinutesExecutionAck.validate(payload, expected: params)
    }

    /// Read-only recovery using the original durable request; never redispatch.
    func minutesExecutionResult(_ expected: MinutesExecutionSendParams) async throws -> MinutesExecutionRead {
        registerMinutesExecutionRunID(expected.idempotencyKey)
        let params = MinutesResultGetParams(sessionKey: expected.sessionKey, runId: expected.idempotencyKey)
        return try MinutesExecutionRead.validate(try await request(method: "chat.result.get", params: params), expected: expected)
    }
}
