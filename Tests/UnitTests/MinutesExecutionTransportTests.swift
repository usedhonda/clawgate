import XCTest
@testable import ClawGate

final class MinutesExecutionTransportTests: XCTestCase {
    private let owner = MinutesResultGetParams(sessionKey: "agent:example:main", runId: "part-attempt")

    private func payload(_ value: [String: Any]) throws -> IncomingPayload {
        try JSONDecoder().decode(IncomingPayload.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private var ack: [String: Any] {
        ["status": "started", "sessionKey": owner.sessionKey, "runId": owner.runId,
         "resolvedModel": "openai/gpt-6.1-sol", "resolvedThinking": "high", "degraded": false,
         "fallbackReason": NSNull(), "isolationApplied": true, "nonprojectionApplied": true,
         "resultRetentionExpiresAt": NSNull()]
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
        XCTAssertEqual(try MinutesExecutionAck.validate(payload(ack), expected: owner).runId, owner.runId)
        let mutations: [(String, Any)] = [("runId", "other-run"), ("sessionKey", "other-session"),
            ("resolvedModel", "openai/gpt-6-sol"), ("resolvedThinking", "medium"),
            ("degraded", true), ("fallbackReason", "unavailable"), ("isolationApplied", false),
            ("nonprojectionApplied", false), ("resultRetentionExpiresAt", 123)]
        for (key, value) in mutations {
            var changed = ack; changed[key] = value
            XCTAssertThrowsError(try MinutesExecutionAck.validate(payload(changed), expected: owner), key)
        }
        for key in ["fallbackReason", "resultRetentionExpiresAt", "isolationApplied", "nonprojectionApplied"] {
            var changed = ack; changed.removeValue(forKey: key)
            XCTAssertThrowsError(try MinutesExecutionAck.validate(payload(changed), expected: owner), key)
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
            "runId": owner.runId, "resultRetentionExpiresAt": NSNull()]
        XCTAssertEqual(try MinutesExecutionResult.validate(payload(response), expected: owner), .pending)
        response["status"] = "expired"
        XCTAssertEqual(try MinutesExecutionResult.validate(payload(response), expected: owner), .expired)
        XCTAssertEqual(try MinutesExecutionResult.validate(payload(["status": "notFound"]), expected: owner), .notFound)
        response["status"] = "terminal"; response["resultRetentionExpiresAt"] = 1_800_000_000
        response["terminal"] = ["kind": "answer", "answer": "fixture-result"]
        XCTAssertEqual(try MinutesExecutionResult.validate(payload(response), expected: owner), .answer("fixture-result"))
        response["terminal"] = ["kind": "error", "code": "timeout", "retriable": true]
        XCTAssertEqual(try MinutesExecutionResult.validate(payload(response), expected: owner), .failed(code: "timeout", retriable: true))
        response["terminal"] = ["kind": "aborted"]
        XCTAssertEqual(try MinutesExecutionResult.validate(payload(response), expected: owner), .aborted)
        response["runId"] = "other-run"
        XCTAssertThrowsError(try MinutesExecutionResult.validate(payload(response), expected: owner))
    }

    func testMalformedTerminalAndMixedBodyFailClosed() throws {
        var response: [String: Any] = ["status": "terminal", "sessionKey": owner.sessionKey,
            "runId": owner.runId, "resultRetentionExpiresAt": 1_800_000_000]
        for terminal: [String: Any] in [["kind": "error", "code": "timeout", "retriable": true, "answer": "untrusted"],
            ["kind": "answer"], ["kind": "aborted", "answer": "untrusted"], ["kind": "future"],
            ["kind": "error", "code": "body with spaces", "retriable": false]] {
            response["terminal"] = terminal
            XCTAssertThrowsError(try MinutesExecutionResult.validate(payload(response), expected: owner))
        }
        response["terminal"] = ["kind": "answer", "answer": "fixture"]
        response["resultRetentionExpiresAt"] = "not-an-epoch"
        XCTAssertThrowsError(try MinutesExecutionResult.validate(payload(response), expected: owner))
    }
}
