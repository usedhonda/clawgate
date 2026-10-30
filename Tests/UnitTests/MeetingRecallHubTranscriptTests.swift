import XCTest
@testable import ClawGate

final class MeetingRecallHubTranscriptTests: XCTestCase {
    private let event = "00000000-0000-0000-0000-000000000001"
    private let result = "00000000-0000-0000-0000-000000000002"

    private func fixture() -> [String: Any] {
        ["status": "ok", "source": "hub-stt", "kind": "voicelog.audio-transcript.v1",
         "processingVersion": "local-stt-v1", "bodySuppressed": false, "errors": [],
         "ids": ["event_id": event, "result_id": result,
                 "parent_refs": [["source": "recall", "external_id": "fixture-original",
                                  "event_id": "00000000-0000-0000-0000-000000000003"]]],
         "privacy": ["status": "unknown"], "capture": ["status": "unknown"],
         "result": ["status": "partial", "text": "Selected speech",
                    "segments": [["start_sec": 3.5, "end_sec": 9.5, "text": "Selected speech",
                                  "speaker_label": "speaker_1"]]]]
    }

    private func read(_ value: [String: Any], selectedEvent: String? = nil) throws -> MeetingRecallHubTranscript {
        try MeetingRecallHubTranscript(authorizedProjection: JSONSerialization.data(withJSONObject: value),
            selectedEventID: selectedEvent ?? event, selectedResultID: result)
    }

    func testAuthorizedSelectionKeepsLineageOffsetsAndUnknownCaptureWithoutNamingSpeaker() throws {
        let transcript = try read(fixture())
        XCTAssertEqual(transcript.eventID, event)
        XCTAssertEqual(transcript.resultID, result)
        XCTAssertEqual(transcript.processingVersion, "local-stt-v1")
        XCTAssertEqual(transcript.parents.first?.source, "recall")
        XCTAssertEqual(transcript.speakerLabels, ["speaker_1"])
        XCTAssertEqual(transcript.segments.first?.startSeconds, 3.5)
        XCTAssertEqual(transcript.segments.first?.endSeconds, 9.5)
        XCTAssertNil(transcript.segments.first?.capturedAt)
        XCTAssertNil(transcript.segments.first?.speaker)
        XCTAssertTrue(transcript.coverageHints.contains { $0.contains("部分的") })
        XCTAssertTrue(transcript.coverageHints.contains { $0.contains("実録音時刻") })
    }

    func testUnselectedOrNonRecallResultCannotBecomeMeetingSpeech() throws {
        XCTAssertThrowsError(try read(fixture(), selectedEvent: "00000000-0000-0000-0000-000000000004")) {
            XCTAssertEqual($0 as? MeetingRecallHubTranscript.ImportError, .selectionMismatch)
        }
        var wrong = fixture()
        wrong["ids"] = ["event_id": event, "result_id": result,
                        "parent_refs": [["source": "clawgate", "external_id": "other-original",
                                         "event_id": "00000000-0000-0000-0000-000000000003"]]]
        XCTAssertThrowsError(try read(wrong)) {
            XCTAssertEqual($0 as? MeetingRecallHubTranscript.ImportError, .unverifiedParents)
        }
    }

    func testSuppressedSensitiveAndInvalidOffsetsDoNotReachSpeech() throws {
        XCTAssertThrowsError(try read(["status": "metadata_only", "bodySuppressed": true])) {
            XCTAssertEqual($0 as? MeetingRecallHubTranscript.ImportError, .bodyUnavailable)
        }
        var sensitive = fixture(); sensitive["privacy"] = ["status": "sensitive"]
        XCTAssertThrowsError(try read(sensitive)) {
            XCTAssertEqual($0 as? MeetingRecallHubTranscript.ImportError, .bodyUnavailable)
        }
        var invalid = fixture()
        invalid["result"] = ["status": "complete", "text": "Selected speech",
                             "segments": [["start_sec": -1, "end_sec": 3, "text": "Selected speech"]]]
        XCTAssertThrowsError(try read(invalid)) {
            XCTAssertEqual($0 as? MeetingRecallHubTranscript.ImportError, .invalidProjection)
        }
    }
}
