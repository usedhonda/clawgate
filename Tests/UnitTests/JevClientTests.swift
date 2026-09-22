import XCTest
@testable import ClawGate

/// `JevClient.parse` and `.buildBody` are pure — no networking in this file.
final class JevClientTests: XCTestCase {
    // MARK: - parse

    func testParsingTheRealExampleResponse() throws {
        let json = """
        {"model":"jev-1.13.0","answers":{"late_night":{"type":"noul","noul":0.45}},
         "usage":{"input_tokens":373,"output_tokens":22}}
        """
        let parsed = try JevClient.parse(Data(json.utf8), requestedModel: "jev-1.13.0",
                                         questionIds: ["late_night"])
        XCTAssertEqual(parsed.answers["late_night"], 0.45)
        XCTAssertEqual(parsed.usage, JevUsage(inputTokens: 373, outputTokens: 22))
        XCTAssertEqual(parsed.model, "jev-1.13.0")
        XCTAssertTrue(parsed.invalid.isEmpty)
    }

    func testAnOutOfRangeAnswerIsInvalidWhileTheOtherIsKept() throws {
        let json = """
        {"model":"jev-1.13.0",
         "answers":{"a":{"type":"noul","noul":0.5},"b":{"type":"noul","noul":1.7}},
         "usage":{"input_tokens":10,"output_tokens":2}}
        """
        let parsed = try JevClient.parse(Data(json.utf8), requestedModel: "jev-1.13.0",
                                         questionIds: ["a", "b"])
        XCTAssertEqual(parsed.answers, ["a": 0.5])
        XCTAssertEqual(parsed.invalid, ["b"])
    }

    func testAMissingIdIsInvalid() throws {
        let json = """
        {"model":"jev-1.13.0","answers":{"a":{"type":"noul","noul":0.5}},
         "usage":{"input_tokens":10,"output_tokens":2}}
        """
        let parsed = try JevClient.parse(Data(json.utf8), requestedModel: "jev-1.13.0",
                                         questionIds: ["a", "missing"])
        XCTAssertEqual(parsed.answers, ["a": 0.5])
        XCTAssertEqual(parsed.invalid, ["missing"])
    }

    func testAResponseMissingAnswersThrowsContract() {
        let json = "{\"model\":\"jev-1.13.0\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
        XCTAssertThrowsError(try JevClient.parse(Data(json.utf8), requestedModel: "jev-1.13.0",
                                                  questionIds: ["a"])) { error in
            XCTAssertEqual(error as? JevError, .contract)
        }
    }

    func testNonJSONThrowsBadJSON() {
        XCTAssertThrowsError(try JevClient.parse(Data("not json at all".utf8),
                                                  requestedModel: "jev-1.13.0",
                                                  questionIds: ["a"])) { error in
            XCTAssertEqual(error as? JevError, .badJSON)
        }
    }

    func testUsageAndModelDefaultWhenMissing() throws {
        let json = "{\"answers\":{\"a\":{\"type\":\"noul\",\"noul\":0.2}}}"
        let parsed = try JevClient.parse(Data(json.utf8), requestedModel: "jev-1.13.0",
                                         questionIds: ["a"])
        XCTAssertEqual(parsed.usage, JevUsage(inputTokens: 0, outputTokens: 0))
        XCTAssertEqual(parsed.model, "jev-1.13.0")
    }

    // MARK: - buildBody

    func testBuildBodyHasExactlyTheThreeTopLevelKeysAndThePinnedModel() throws {
        let data = try JevClient.buildBody(state: "hello",
                                           questions: ["q": .noul("instructions", yes: "y", no: "n")])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["state", "model", "questions"])
        XCTAssertEqual(json["state"] as? String, "hello")
        XCTAssertEqual(json["model"] as? String, "jev-1.13.0")
    }

    // MARK: - JevQuestion.noul

    func testNoulEncodesTypeInstructionsAndCriteria() throws {
        let question = JevQuestion.noul("instructions text", yes: "yes example", no: "no example")
        let data = try JSONEncoder().encode(question)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "noul")
        XCTAssertEqual(json["instructions"] as? String, "instructions text")
        let criteria = try XCTUnwrap(json["criteria"] as? [String: String])
        XCTAssertEqual(criteria["true"], "yes example")
        XCTAssertEqual(criteria["false"], "no example")
    }

    // MARK: - Key tag (transport-safe logging)

    func testKeyTagNeverContainsTheKeyAndIsStable() {
        let tag1 = JevKeyStore.tag(of: "test-key-1234")
        let tag2 = JevKeyStore.tag(of: "test-key-1234")
        XCTAssertFalse(tag1.contains("test-key-1234"))
        XCTAssertEqual(tag1, tag2)
        XCTAssertNotEqual(tag1, JevKeyStore.tag(of: "a-different-test-key"))
    }
}
