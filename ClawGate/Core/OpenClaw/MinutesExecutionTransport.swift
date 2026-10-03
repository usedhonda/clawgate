import Foundation

/// Dedicated minutes wire, not a replacement for ordinary chat or Pet Log.
/// No production caller until the Gateway activation gate is satisfied.
struct MinutesExecutionSendParams: Encodable {
    static let model = "openai/gpt-6.1-sol"
    static let thinking = "high"
    let sessionKey: String
    let message: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case sessionKey, message, idempotencyKey, model, thinking
        case requestLocalContext, nonprojection, retainTerminalResult
    }

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
    case invalidResult
}

struct MinutesExecutionAck: Equatable {
    let sessionKey: String
    let runId: String

    static func validate(_ payload: IncomingPayload?, expected: MinutesResultGetParams) throws -> Self {
        guard let p = payload, p.status == "started" || p.status == "pending",
              p.hasFallbackReason, p.hasResultRetentionExpiresAt,
              p.resultRetentionExpiresAt == nil else {
            throw MinutesExecutionTransportError.invalidAcknowledgement
        }
        guard p.sessionKey == expected.sessionKey, p.runId == expected.runId,
              !expected.sessionKey.isEmpty, !expected.runId.isEmpty else {
            throw MinutesExecutionTransportError.identityMismatch
        }
        guard p.resolvedModel == MinutesExecutionSendParams.model,
              p.resolvedThinking == MinutesExecutionSendParams.thinking,
              p.degraded == false, p.fallbackReason == nil else {
            throw MinutesExecutionTransportError.modelMismatch
        }
        guard p.isolationApplied == true, p.nonprojectionApplied == true else {
            throw MinutesExecutionTransportError.isolationNotApplied
        }
        return Self(sessionKey: expected.sessionKey, runId: expected.runId)
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

    static func validate(_ payload: IncomingPayload?, expected: MinutesResultGetParams) throws -> Self {
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
                  p.minutesTerminal == nil else { throw MinutesExecutionTransportError.invalidResult }
            return .pending
        case "expired":
            guard p.minutesTerminal == nil else { throw MinutesExecutionTransportError.invalidResult }
            return .expired
        case "terminal":
            guard let expiry = p.resultRetentionEpoch, expiry.isFinite, expiry > 0,
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
    /// The caller must durably reserve this key first. Never retry as chat.
    func sendMinutesExecution(_ message: String, sessionKey: String,
                              idempotencyKey: String) async throws -> MinutesExecutionAck {
        let payload = try await request(method: "chat.send", params: MinutesExecutionSendParams(
            sessionKey: sessionKey, message: message, idempotencyKey: idempotencyKey))
        return try MinutesExecutionAck.validate(payload, expected: .init(sessionKey: sessionKey, runId: idempotencyKey))
    }

    /// Read-only recovery; neither this function nor its errors redispatch.
    func minutesExecutionResult(sessionKey: String, runId: String) async throws -> MinutesExecutionResult {
        let params = MinutesResultGetParams(sessionKey: sessionKey, runId: runId)
        return try MinutesExecutionResult.validate(try await request(method: "chat.result.get", params: params),
                                                  expected: params)
    }
}
