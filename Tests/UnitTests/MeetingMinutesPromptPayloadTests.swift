import XCTest
@testable import ClawGate

final class MeetingMinutesPromptPayloadTests: XCTestCase {
    func testPromptProjectionDropsRepeatedMetadataWithoutDroppingEvidenceOrTiming() throws {
        let record = MeetingRecord(id: "meeting-payload", source: "meet", startedAt: 1_700_000_000,
                                   endedAt: 1_700_000_600, timeZone: "UTC", title: "Payload",
                                   conferenceCode: "abc-def", participants: ["Ada"],
                                   minutesState: "none", minutesError: nil)
        let local = TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "local speech",
                                      capturedAt: 1_700_000_001, timeZone: "UTC", speaker: "self",
                                      stream: "mic", speakerName: nil)
        let externalJSON = #"""
            "id":"meet-1", "capturedAt":1700000002, "startSeconds":12.5,
            "endSeconds":14.25, "speaker":"Ada", "stream":"system",
            "speakerName":"Ada", "text":"Meet speech", "source":"meet",
            "sourceURL":"https://meet.google.com/call?tab=transcript",
            "sourceLocator":"calendar:00:12.5"
        """#
        let external = try JSONDecoder().decode(MeetingMinutesSegment.self, from: Data(("{" + externalJSON + "}").utf8))
        var envelope = MeetingMinutesEnvelope.build(record: record, segments: [local])
        envelope = envelope.replacingSegments([envelope.segments[0], external])

        let message = try MeetingMinutesPrompt.buildMessage(envelope: envelope)
        let jsonText = try XCTUnwrap(message.components(separatedBy: "\n\n").last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any])
        let segments = try XCTUnwrap(payload["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 2)

        let localPayload = try XCTUnwrap(segments[0])
        XCTAssertEqual(localPayload["id"] as? String, "seg-1")
        XCTAssertEqual(localPayload["text"] as? String, "local speech")
        XCTAssertEqual(localPayload["capturedAt"] as? Double, 1_700_000_001)
        XCTAssertEqual(localPayload["startSeconds"] as? Double, 0)
        XCTAssertEqual(localPayload["endSeconds"] as? Double, 2)

        let externalPayload = try XCTUnwrap(segments[1])
        XCTAssertEqual(externalPayload["id"] as? String, "meet-1")
        XCTAssertEqual(externalPayload["text"] as? String, "Meet speech")
        XCTAssertEqual(externalPayload["source"] as? String, "meet")
        XCTAssertEqual(externalPayload["sourceLocator"] as? String, "calendar:00:12.5")
        XCTAssertEqual(externalPayload["capturedAt"] as? Double, 1_700_000_002)
        XCTAssertEqual(externalPayload["startSeconds"] as? Double, 12.5)
        XCTAssertEqual(externalPayload["endSeconds"] as? Double, 14.25)
        XCTAssertEqual(externalPayload["speakerName"] as? String, "Ada")
        XCTAssertEqual(externalPayload["stream"] as? String, "system")
        XCTAssertNil(externalPayload["speaker"])
        XCTAssertNil(externalPayload["sourceURL"])

        let storageData = try JSONEncoder().encode(envelope)
        let storage = try XCTUnwrap(JSONSerialization.jsonObject(with: storageData) as? [String: Any])
        let storedSegments = try XCTUnwrap(storage["segments"] as? [[String: Any]])
        XCTAssertEqual(storedSegments[1]["sourceURL"] as? String,
                       "https://meet.google.com/call?tab=transcript")
        XCTAssertLessThan(jsonText.utf8.count, storageData.count)
    }
}
