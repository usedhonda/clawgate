import XCTest
@testable import ClawGate

final class MeetingMinutesPromptPayloadTests: XCTestCase {
    func testPromptGroupsSplitSpeechWithoutDiscardingOriginalsOrConflicts() throws {
        let record = MeetingRecord(id: "meeting-grouping", source: "meet", startedAt: 100,
            endedAt: 200, timeZone: "UTC", title: "Grouping", conferenceCode: nil,
            participants: [], minutesState: "none", minutesError: nil)
        let sources: [MeetingTranscriptSourceSegment] = [
            .init(id: "whole", source: "local", text: "Budget is 23 million", capturedAt: 110),
            .init(id: "part-a", source: "meet", text: "Budget is", capturedAt: 110),
            .init(id: "part-b", source: "meet", text: "23 million", capturedAt: 111),
            .init(id: "conflict", source: "recall", text: "Budget is not 23 million", capturedAt: 110),
            .init(id: "untimed", source: "other", text: "Budget is 23 million"),
            .init(id: "secondary", source: "existing-minutes", text: "Budget is 23 million", capturedAt: 110)
        ]
        let envelope = MeetingMinutesEnvelope.build(record: record, sourceSegments: sources)
        let original = try JSONEncoder().encode(envelope)
        let message = try MeetingMinutesPrompt.buildMessage(envelope: envelope)
        let json = try XCTUnwrap(message.components(separatedBy: "\n\n").last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let lines = try XCTUnwrap(payload["segments"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 4)
        let whole = try XCTUnwrap(lines.first { $0["id"] as? String == "whole" })
        let aliases = try XCTUnwrap(whole["equivalentSources"] as? [[String: Any]])
        XCTAssertEqual(aliases.compactMap { $0["id"] as? String }, ["part-a", "part-b"])
        XCTAssertEqual(aliases.compactMap { $0["capturedAt"] as? Double }, [110, 111])
        XCTAssertTrue(aliases.allSatisfy { $0["text"] == nil })
        XCTAssertEqual(Set(lines.compactMap { $0["id"] as? String }), ["whole", "conflict", "untimed", "secondary"])
        let restored = try JSONDecoder().decode(MeetingMinutesEnvelope.self, from: original)
        XCTAssertEqual(restored, envelope)
        XCTAssertEqual(restored.segments.map(\.text), sources.map(\.text))
        // Repeated same-time lines are ambiguous, not extra corroboration.
        let ambiguous = [sources[0], sources[1], sources[2],
            MeetingTranscriptSourceSegment(id: "repeat", source: "meet", text: sources[0].text, capturedAt: 111)]
        XCTAssertEqual(MeetingTranscriptFusion.equivalentGroups(ambiguous).count, 4)
    }

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
