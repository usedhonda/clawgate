import XCTest
@testable import ClawGate

final class HubAudioAdmissionTests: XCTestCase {
    private let event = "00000000-0000-4000-8000-000000000001"
    private let job = "00000000-0000-4000-8000-000000000002"
    private let digest = String(repeating: "a", count: 64)

    private func response(original: Bool = true, processingChanges: [String: Any] = [:], omitProcessing: Bool = false) throws -> Data {
        let storage: [String: Any] = ["receipt_version": 1, "source": "clawgate", "external_id": "fixture-original",
            "event_id": event, "sha256": original ? digest as Any : NSNull(), "byte_length": original ? 123 : 0, "ingest_sequence": 7]
        var object: [String: Any] = ["storage_receipt": storage]
        if original && !omitProcessing {
            var processing: [String: Any] = ["receipt_version": 1, "intent_committed": true, "job_id": job,
                "original_event_id": event, "pipeline_version": "local-stt-v1", "state": "pending"]
            processing.merge(processingChanges) { _, new in new }
            object["processing_receipt"] = processing
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testOriginalRequiresStorageAndMatchingDurableJob() throws {
        let accepted = try HubAudioAdmission.validate(response: response(), externalID: "fixture-original", sha256: digest,
                                                     byteLength: 123, pipeline: "local-stt-v1")
        XCTAssertEqual(accepted.binding.eventID, event)
        XCTAssertEqual(accepted.binding.jobID, job)
        XCTAssertThrowsError(try HubAudioAdmission.validate(response: response(omitProcessing: true), externalID: "fixture-original",
                                                            sha256: digest, byteLength: 123, pipeline: "local-stt-v1"))
        for change: [String: Any] in [["intent_committed": false], ["original_event_id": job],
                                     ["job_id": "invalid"], ["pipeline_version": "different"], ["state": "invented"]] {
            XCTAssertThrowsError(try HubAudioAdmission.validate(response: response(processingChanges: change), externalID: "fixture-original",
                                                               sha256: digest, byteLength: 123, pipeline: "local-stt-v1"))
        }
        XCTAssertThrowsError(try HubAudioAdmission.validate(response: response(), externalID: "fixture-original",
                                                            sha256: digest, byteLength: 124, pipeline: "local-stt-v1"))
    }

    func testMutableProgressDoesNotChangeBindingAndRebindingFails() throws {
        let first = try HubAudioAdmission.validate(response: response(), externalID: "fixture-original", sha256: digest, byteLength: 123, pipeline: "local-stt-v1")
        let later = try HubAudioAdmission.validate(response: response(processingChanges: ["state": "completed"]), externalID: "fixture-original",
                                                   sha256: digest, byteLength: 123, pipeline: "local-stt-v1", previous: first.binding)
        XCTAssertEqual(first.binding, later.binding)
        XCTAssertThrowsError(try HubAudioAdmission.validate(response: response(processingChanges: ["job_id": event]), externalID: "fixture-original",
                                                            sha256: digest, byteLength: 123, pipeline: "local-stt-v1", previous: first.binding))
    }

    func testMetadataOnlyNeedsNoSTTIntentAndCannotAcknowledgeOriginal() throws {
        let data = try response(original: false)
        let result = try HubAudioAdmission.validate(response: data, externalID: "fixture-original", sha256: nil, byteLength: 0, pipeline: nil)
        XCTAssertNil(result.processingReceipt)
        XCTAssertNil(result.binding.jobID)
        XCTAssertThrowsError(try HubAudioAdmission.validate(response: data, externalID: "fixture-original", sha256: digest, byteLength: 123, pipeline: "local-stt-v1"))
    }
}
