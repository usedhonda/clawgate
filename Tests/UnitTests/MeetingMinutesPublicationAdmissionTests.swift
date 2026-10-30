import XCTest
@testable import ClawGate

final class MeetingMinutesPublicationAdmissionTests: XCTestCase {
    func testTypedReceiptAndExactAdmissionErrorDoNotConfuseOrdinaryOrMalformedResponses() throws {
        let receipt = MeetingMinutesPublicationReceipt(schemaVersion: 1,
            sourceUUID: "00000000-0000-4000-8000-000000000001", meetingID: "fixture",
            publicationOrdinal: 1, outputRevision: "sha256:" + String(repeating: "0", count: 64),
            payloadSHA256: String(repeating: "a", count: 64), status: .searchable, isCurrent: true)
        let data = try JSONEncoder().encode(receipt)
        XCTAssertEqual(try JSONDecoder().decode(IncomingPayload.self, from: data).minutesPublicationReceipt, receipt)
        let ordinary = try JSONDecoder().decode(IncomingPayload.self, from: Data("{\"stateAccepted\":true}".utf8))
        XCTAssertNil(ordinary.minutesPublicationReceipt)
        XCTAssertEqual(ordinary.stateAccepted, true)
        var wrong = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        wrong["isCurrent"] = "true"
        XCTAssertNil(try JSONDecoder().decode(IncomingPayload.self,
            from: JSONSerialization.data(withJSONObject: wrong)).minutesPublicationReceipt)
        XCTAssertEqual(MeetingMinutesPublicationAdmission.classify(OpenClawError.serverError(
            code: "INVALID_REQUEST", message: "MINUTES_DOCUMENT_INVALID")), .confirmedDocumentRejection)
        XCTAssertEqual(MeetingMinutesPublicationAdmission.classify(OpenClawError.serverError(
            code: "INVALID_REQUEST", message: "MINUTES_SOURCE_UNBOUND")), .sourceUnbound)
        XCTAssertEqual(MeetingMinutesPublicationAdmission.classify(OpenClawError.serverError(
            code: "INVALID_REQUEST", message: "Other response containing MINUTES_DOCUMENT_INVALID")), .unknownFailure)
        XCTAssertEqual(MeetingMinutesPublicationAdmission.classify(OpenClawError.timeout), .unknownFailure)
    }
}
