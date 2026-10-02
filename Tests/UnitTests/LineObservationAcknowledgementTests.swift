import XCTest
@testable import ClawGate

final class LineObservationAcknowledgementTests: XCTestCase {
    func testUnknownOrMalformedAcknowledgementCannotDequeue() throws {
        let sent: Set<String> = ["line:sample:1", "line:sample:2"]
        let unknown = try JSONSerialization.data(withJSONObject: ["ok": true, "ackedObservationIds": ["line:other:1"]])
        XCTAssertNil(LineObservationAcknowledgement.parse(data: unknown, sentIDs: sent))
        let missing = try JSONSerialization.data(withJSONObject: ["ok": true])
        XCTAssertNil(LineObservationAcknowledgement.parse(data: missing, sentIDs: sent))
        let partial = try JSONSerialization.data(withJSONObject: ["ok": true, "ackedObservationIds": ["line:sample:1"],
            "rejected": [["observationId": "line:sample:2", "code": "conflict", "permanent": true]]])
        let parsed = try XCTUnwrap(LineObservationAcknowledgement.parse(data: partial, sentIDs: sent))
        XCTAssertEqual(parsed.acked, ["line:sample:1"])
        XCTAssertEqual(parsed.permanentRejected.first?.id, "line:sample:2")
    }
    func testPermanentRejectionSurvivesRestartWithoutStarvingLaterData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try LineObservationOutbox(directory: root)
        try queue.enqueue(Data("sample-one".utf8), observationID: "one")
        try queue.enqueue(Data("sample-two".utf8), observationID: "two")
        try queue.markRejected(["one"], code: "conflict")
        let reopened = try LineObservationOutbox(directory: root)
        XCTAssertEqual(try reopened.pending().map(\.id), ["two"])
        XCTAssertEqual(reopened.queuedCount, 2)
        XCTAssertEqual(reopened.rejectedCount, 1)
    }
}
