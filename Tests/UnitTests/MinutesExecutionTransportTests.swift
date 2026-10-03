import XCTest
@testable import ClawGate

final class MinutesExecutionTransportTests: XCTestCase {
    private let owner = MinutesResultGetParams(sessionKey: "agent:example:main", runId: "part-attempt")

    private var request: MinutesExecutionSendParams {
        .init(sessionKey: owner.sessionKey, message: "fixture", idempotencyKey: owner.runId)
    }
    private var binding: [String: Any] {
        ["version": 1, "requestFingerprintScheme": MinutesRequestFingerprint.scheme,
         "requestFingerprint": try! request.requestFingerprint(), "resolvedModel": MinutesExecutionSendParams.model,
         "resolvedThinking": "high", "degraded": false, "fallbackReason": NSNull(),
         "isolationApplied": true, "nonprojectionApplied": true, "retentionApplied": true]
    }

    private func payload(_ value: [String: Any]) throws -> IncomingPayload {
        try JSONDecoder().decode(IncomingPayload.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private var ack: [String: Any] {
        ["status": "started", "sessionKey": owner.sessionKey, "runId": owner.runId,
         "resolvedModel": "openai/gpt-6.1-sol", "resolvedThinking": "high", "degraded": false,
         "fallbackReason": NSNull(), "isolationApplied": true, "nonprojectionApplied": true,
         "resultRetentionExpiresAt": NSNull(), "executionBinding": binding]
    }

    func testExactMinutesModelAndIsolationNeverAlterOrdinaryParams() throws {
        let request = MinutesExecutionSendParams(sessionKey: owner.sessionKey, message: "fixture", idempotencyKey: owner.runId)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        XCTAssertEqual(Set(encoded.keys), ["sessionKey", "message", "idempotencyKey", "model", "thinking",
                                           "requestLocalContext", "nonprojection", "retainTerminalResult"])
        XCTAssertEqual(encoded["model"] as? String, "openai/gpt-6.1-sol")
        XCTAssertEqual(encoded["thinking"] as? String, "high")
        for field in ["requestLocalContext", "nonprojection", "retainTerminalResult"] {
            XCTAssertEqual(encoded[field] as? Bool, true)
        }
        let ordinary = ChatSendParams(sessionKey: owner.sessionKey, message: "fixture", idempotencyKey: owner.runId)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinary)) as! [String: Any]
        XCTAssertEqual(Set(plain.keys), ["sessionKey", "message", "idempotencyKey"])
        XCTAssertEqual(PetLogChatSendParams.canonicalModel, "openai/gpt-5.6-sol")
    }

    func testAckRequiresExactOwnerModelAndAllAppliedGuarantees() throws {
        XCTAssertEqual(try MinutesExecutionAck.validate(payload(ack), expected: request).runId, owner.runId)
        let mutations: [(String, Any)] = [("runId", "other-run"), ("sessionKey", "other-session"),
            ("resolvedModel", "openai/gpt-6-sol"), ("resolvedThinking", "medium"),
            ("degraded", true), ("fallbackReason", "unavailable"), ("isolationApplied", false),
            ("nonprojectionApplied", false), ("resultRetentionExpiresAt", 123)]
        for (key, value) in mutations {
            var changed = ack; changed[key] = value
            XCTAssertThrowsError(try MinutesExecutionAck.validate(payload(changed), expected: request), key)
        }
        for key in ["fallbackReason", "resultRetentionExpiresAt", "isolationApplied", "nonprojectionApplied", "executionBinding"] {
            var changed = ack; changed.removeValue(forKey: key)
            XCTAssertThrowsError(try MinutesExecutionAck.validate(payload(changed), expected: request), key)
        }
    }

    func testSequentialMinutesUsesExactModelWithoutClaimingIsolation() throws {
        let request = MinutesModelSendParams(sessionKey: owner.sessionKey, message: "fixture", idempotencyKey: owner.runId)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        XCTAssertEqual(Set(value.keys), ["sessionKey", "message", "idempotencyKey", "model", "thinking"])
        XCTAssertEqual(value["model"] as? String, "openai/gpt-6.1-sol")
        XCTAssertEqual(value["thinking"] as? String, "high")
        var response = ack
        for key in ["sessionKey", "isolationApplied", "nonprojectionApplied", "resultRetentionExpiresAt"] {
            response.removeValue(forKey: key)
        }
        XCTAssertEqual(try MinutesModelAck.validate(payload(response), expectedRunID: owner.runId), owner.runId)
        response["degraded"] = true
        XCTAssertThrowsError(try MinutesModelAck.validate(payload(response), expectedRunID: owner.runId))
        response["degraded"] = false; response["fallbackReason"] = "model_unavailable"
        XCTAssertThrowsError(try MinutesModelAck.validate(payload(response), expectedRunID: owner.runId))
        response["fallbackReason"] = NSNull(); response["resolvedThinking"] = "medium"
        XCTAssertThrowsError(try MinutesModelAck.validate(payload(response), expectedRunID: owner.runId))
        response["resolvedThinking"] = "high"; response["resolvedModel"] = "openai/gpt-6-sol"
        XCTAssertThrowsError(try MinutesModelAck.validate(payload(response), expectedRunID: owner.runId))
        response["resolvedModel"] = "openai/gpt-6.1-sol"; response["runId"] = "another"
        XCTAssertThrowsError(try MinutesModelAck.validate(payload(response), expectedRunID: owner.runId))
    }

    func testTypedRecoveryPreservesPendingAndUnavailableWithoutGeneration() throws {
        var response: [String: Any] = ["status": "pending", "sessionKey": owner.sessionKey,
            "runId": owner.runId, "resultRetentionExpiresAt": NSNull(), "executionBinding": binding]
        XCTAssertEqual(try MinutesExecutionRead.validate(payload(response), expected: request).result, .pending)
        response["status"] = "expired"; response.removeValue(forKey: "resultRetentionExpiresAt")
        XCTAssertEqual(try MinutesExecutionRead.validate(payload(response), expected: request).result, .expired)
        XCTAssertEqual(try MinutesExecutionRead.validate(payload(["status": "notFound"]), expected: request).result, .notFound)
        response["status"] = "terminal"; response["resultRetentionExpiresAt"] = 1_800_000_000
        response["terminal"] = ["kind": "answer", "answer": "fixture-result"]
        XCTAssertEqual(try MinutesExecutionRead.validate(payload(response), expected: request).result, .answer("fixture-result"))
        response["terminal"] = ["kind": "error", "code": "timeout", "retriable": true]
        XCTAssertEqual(try MinutesExecutionRead.validate(payload(response), expected: request).result, .failed(code: "timeout", retriable: true))
        response["terminal"] = ["kind": "aborted"]
        XCTAssertEqual(try MinutesExecutionRead.validate(payload(response), expected: request).result, .aborted)
        response["runId"] = "other-run"
        XCTAssertThrowsError(try MinutesExecutionRead.validate(payload(response), expected: request))
    }

    func testMalformedTerminalAndMixedBodyFailClosed() throws {
        var response: [String: Any] = ["status": "terminal", "sessionKey": owner.sessionKey,
            "runId": owner.runId, "resultRetentionExpiresAt": 1_800_000_000_000, "executionBinding": binding]
        for terminal: [String: Any] in [["kind": "error", "code": "timeout", "retriable": true, "answer": "untrusted"],
            ["kind": "answer"], ["kind": "aborted", "answer": "untrusted"], ["kind": "future"],
            ["kind": "error", "code": "body with spaces", "retriable": false]] {
            response["terminal"] = terminal
            XCTAssertThrowsError(try MinutesExecutionRead.validate(payload(response), expected: request))
        }
        response["terminal"] = ["kind": "answer", "answer": "fixture"]
        response["resultRetentionExpiresAt"] = "not-an-epoch"
        XCTAssertThrowsError(try MinutesExecutionRead.validate(payload(response), expected: request))
    }
    func testSharedLP8VectorPreservesExactUnicodeAndNewlines() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/minutes-execution-request-v1.json")
        struct Vector: Decodable { let request: MinutesExecutionSendParams; let scheme: String; let sha256: String }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        XCTAssertEqual(try vector.request.requestFingerprint(), vector.sha256)
        XCTAssertEqual(vector.scheme, MinutesRequestFingerprint.scheme)
        for text in [vector.request.message + "x", vector.request.message.precomposedStringWithCanonicalMapping,
                     vector.request.message.replacingOccurrences(of: "\n", with: "\r\n")] {
            XCTAssertNotEqual(try MinutesExecutionSendParams(sessionKey: vector.request.sessionKey, message: text,
                              idempotencyKey: vector.request.idempotencyKey).requestFingerprint(), vector.sha256)
        }
        let encoded = try JSONEncoder().encode(vector.request)
        XCTAssertEqual(try JSONDecoder().decode(MinutesExecutionSendParams.self, from: encoded).requestFingerprint(), vector.sha256)
    }

    func testRetainedBindingAndExpiryFailClosedWithoutAck() throws {
        let terminal: [String: Any] = ["kind": "answer", "answer": "fixture"]
        var valid: [String: Any] = ["status": "terminal", "sessionKey": owner.sessionKey, "runId": owner.runId,
            "resultRetentionExpiresAt": 1_800_000_000_000, "terminal": terminal, "executionBinding": binding]
        XCTAssertEqual(try MinutesExecutionRead.validate(payload(valid), expected: request).result, .answer("fixture"))
        for (key, value): (String, Any) in [("version", 2), ("requestFingerprint", String(repeating: "0", count: 64)),
            ("requestFingerprintScheme", "other"), ("resolvedModel", "other"), ("resolvedThinking", "low"),
            ("degraded", true), ("fallbackReason", "fallback"), ("retentionApplied", false),
            ("isolationApplied", false), ("nonprojectionApplied", false)] {
            var changed = valid; var b = binding; b[key] = value; changed["executionBinding"] = b
            XCTAssertThrowsError(try MinutesExecutionRead.validate(payload(changed), expected: request), key)
        }
        var missing = valid; missing.removeValue(forKey: "executionBinding")
        XCTAssertThrowsError(try MinutesExecutionRead.validate(payload(missing), expected: request))
        var b = binding; b.removeValue(forKey: "fallbackReason"); missing["executionBinding"] = b
        XCTAssertThrowsError(try MinutesExecutionRead.validate(payload(missing), expected: request))
        for expiry: Any in [0, -1, 1.5, "1800000000000", true, 9_007_199_254_740_992 as UInt64] {
            var changed = valid; changed["resultRetentionExpiresAt"] = expiry
            XCTAssertThrowsError(try MinutesExecutionRead.validate(payload(changed), expected: request))
        }
        valid["resolvedThinking"] = "low"
        XCTAssertThrowsError(try MinutesExecutionRead.validate(payload(valid), expected: request))
        XCTAssertThrowsError(try MinutesExecutionRead.validate(payload(["status": "notFound", "executionBinding": binding]), expected: request))
    }

}
