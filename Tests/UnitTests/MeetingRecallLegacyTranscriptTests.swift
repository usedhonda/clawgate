import XCTest
@testable import ClawGate

final class MeetingRecallLegacyTranscriptTests: XCTestCase {
    func testSelectedLegacyTextKeepsEventBindingWithoutInventingSTTIdentityOrCapture() throws {
        let event = "00000000-0000-4000-8000-000000000001"
        var fixture: [String: Any] = ["status": "ok", "source": "recall", "kind": "transcript",
            "bodySuppressed": false, "contentHashScheme": "hub-event-v1", "contentSha256": String(repeating: "a", count: 64),
            "ids": ["event_id": event, "external_id": "fixture-legacy", "result_id": NSNull()],
            "privacy": ["status": "unknown"], "processingVersion": NSNull(),
            "result": ["status": NSNull(), "text": "Selected existing transcript", "segments": []]]
        func read(_ selected: String = event) throws -> MeetingRecallLegacyTranscript {
            try MeetingRecallLegacyTranscript(authorizedProjection: JSONSerialization.data(withJSONObject: fixture),
                selectedEventID: selected)
        }
        let parsed = try read()
        let segment = try XCTUnwrap(parsed.segments.first)
        XCTAssertEqual(parsed.eventID, event)
        XCTAssertEqual(parsed.externalID, "fixture-legacy")
        XCTAssertEqual(segment.source, "recall")
        XCTAssertNil(segment.recallLineage)
        XCTAssertNil(segment.capturedAt)
        XCTAssertNil(segment.startSeconds)
        XCTAssertNil(segment.endSeconds)
        XCTAssertNil(segment.speaker)
        XCTAssertTrue(segment.sourceLocator?.contains(event) == true)
        XCTAssertTrue(parsed.coverageHints.contains { $0.contains("プライバシー") })
        XCTAssertThrowsError(try read("00000000-0000-4000-8000-000000000002")) {
            XCTAssertEqual($0 as? MeetingRecallLegacyTranscript.ImportError, .selectionMismatch)
        }
        fixture["source"] = "other"
        XCTAssertThrowsError(try read())
        fixture["source"] = "recall"; fixture["kind"] = "transcript_variant"
        XCTAssertEqual(try read().segments.first?.text, segment.text)
        fixture = ["status": "metadata_only", "bodySuppressed": true]
        XCTAssertThrowsError(try read()) {
            XCTAssertEqual($0 as? MeetingRecallLegacyTranscript.ImportError, .bodyUnavailable)
        }
    }
}
