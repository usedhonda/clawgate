import XCTest
@testable import ClawGate

final class MeetingRecallReadBridgeTests: XCTestCase {
    func testCompleteUnicodePagesFenceIdentityAndNeverInventSegmentClocks() async throws {
        let event = "00000000-0000-4000-8000-000000000001"
        let originalID = "00000000-0000-4000-8000-000000000002"
        let resultID = "00000000-0000-4000-8000-000000000003"
        let hash = String(repeating: "a", count: 64)
        let binding: [String: Any] = ["eventId": event, "source": "recall", "externalId": "fixture",
            "kind": "transcript", "resultId": NSNull(), "processingVersion": NSNull(),
            "contentHashScheme": "hub-event-v1", "contentSha256": hash, "parents": [],
            "privacy": "unknown", "metadataOnly": false]
        func page(offset: Int, text: String, next: Int?, changed: Bool = false,
                  suppressed: Bool = false) throws -> MeetingRecallReadBridge.Read {
            var bound = binding
            if changed { bound["contentSha256"] = String(repeating: "b", count: 64) }
            let projection: [String: Any] = ["status": "ok", "kind": "transcript", "source": "recall",
                "ids": ["event_id": event, "external_id": "fixture", "result_id": NSNull(), "parent_refs": []],
                "privacy": ["status": "unknown"], "processingVersion": NSNull(),
                "result": ["status": NSNull(), "text": text, "segments": []], "bodySuppressed": suppressed,
                "contentHashScheme": "hub-event-v1", "contentSha256": bound["contentSha256"]!]
            let response: [String: Any] = ["schemaVersion": 1, "status": "ok", "errorCode": NSNull(),
                "projection": projection, "binding": bound, "originalBinding": NSNull(),
                "page": ["offset": offset, "nextOffset": next as Any? ?? NSNull(),
                    "complete": next == nil, "unit": "unicode_codepoint"]]
            // Exercise the real optional payload decoder as well as the pager.
            let decoded = try JSONDecoder().decode(IncomingPayload.self,
                from: JSONSerialization.data(withJSONObject: response))
            return try XCTUnwrap(decoded.minutesRecallRead)
        }
        let item = MeetingRecallSelectionStore.Item(eventID: event, resultEventID: nil, kind: "transcript")
        var requests: [MeetingRecallReadBridge.ReadRequest] = []
        let read = try await MeetingRecallReadBridge.readSelection(items: [item], selectionFingerprint: "selected",
            sourceUUID: originalID, resolve: { _ in throw MeetingRecallReadBridge.Failure.invalidResponse },
            read: { request in
                requests.append(request)
                return try request.offset == 0 ? page(offset: 0, text: "😀e\u{301}", next: 3) : page(offset: 3, text: "final", next: nil)
            })
        XCTAssertEqual(requests.map(\.offset), [0, 3])
        XCTAssertNil(requests.first?.expectedBinding)
        XCTAssertEqual(requests.last?.expectedBinding?.contentSha256, hash)
        XCTAssertEqual(read.segments.map(\.text), ["😀e\u{301}", "final"])
        XCTAssertTrue(read.segments.allSatisfy { $0.capturedAt == nil && $0.startSeconds == nil && $0.speaker == nil && $0.recallLineage == nil })
        for mode in ["revision", "privacy"] {
            do {
                _ = try await MeetingRecallReadBridge.readSelection(items: [item], selectionFingerprint: "selected",
                    sourceUUID: originalID, resolve: { _ in throw MeetingRecallReadBridge.Failure.invalidResponse },
                    read: { request in
                        try request.offset == 0 ? page(offset: 0, text: "first", next: 5) :
                            page(offset: 5, text: "last", next: nil, changed: mode == "revision", suppressed: mode == "privacy")
                    })
                XCTFail("A failed continuation returned a partial input")
            } catch {}
        }
        let parent = MeetingRecallTranscriptLineage.Parent(source: "recall", externalID: "original", eventID: originalID)
        let original = MeetingRecallReadBridge.Binding(eventId: originalID, source: "recall", externalId: "original",
            kind: "recall.audio-original.v1", resultId: nil, processingVersion: nil,
            contentHashScheme: "hub-event-v1", contentSha256: hash, parents: [], privacy: "clear", metadataOnly: true)
        let derived = MeetingRecallReadBridge.Binding(eventId: event, source: "hub-stt", externalId: "result",
            kind: "voicelog.audio-transcript.v1", resultId: resultID, processingVersion: "fixture-v1",
            contentHashScheme: "hub-event-v1", contentSha256: hash, parents: [parent], privacy: "clear", metadataOnly: false)
        let incomplete = MeetingRecallReadBridge.Resolution(schemaVersion: 1, status: "incomplete", errorCode: nil,
            originalBinding: original, results: [.init(binding: derived, parentVerified: true, multiOriginal: false)],
            relatedTruncated: true, complete: false, unverifiedCount: 0, autoSelectableEventId: event)
        XCTAssertThrowsError(try incomplete.chosen(originalID: originalID, explicitResultID: nil))
        XCTAssertEqual(try incomplete.chosen(originalID: originalID, explicitResultID: event).1, derived)
        let lineage = MeetingRecallTranscriptLineage(eventID: event, resultID: resultID,
            processingVersion: "fixture-v1", parents: [parent], segmentIndex: nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lineage)) as? [String: Any]
        XCTAssertNil(encoded?["segmentIndex"])
    }
}
