import XCTest
@testable import ClawGate

final class LineObservationProtocolTests: XCTestCase {
    func testHubV3RequiresVersionAndSemanticFormat() throws {
        func version(_ value: [String: Any]) throws -> Int? {
            LineObservationProtocol.supportedHubVersion(capabilityData: try JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertEqual(try version(["line_observation_schema_versions": [1, 2, 3], "line_observation_semantic_format": "line-visible-content-v1"]), 3)
        XCTAssertEqual(try version(["line_observation_schema_versions": [1, 2, 3]]), 2)
        XCTAssertNil(try version(["line_observation_schema_versions": [3], "line_observation_semantic_format": "different"]))
        XCTAssertNil(try version([:]))
    }

    @MainActor
    func testV3AddsObservedAttributesWithoutChangingV2OrPromotingIdentity() throws {
        let rows = [LineOCRRow(text: "first line", box: .init(x: 0.15, y: 0.45, width: 0.6, height: 0.04)),
                    LineOCRRow(text: "second line", box: .init(x: 0.15, y: 0.40, width: 0.6, height: 0.04)),
                    LineOCRRow(text: "午後 1:23", box: .init(x: 0.85, y: 0.39, width: 0.1, height: 0.025))]
        let legacy = LineBodyCandidateExtractor.extract(rows: rows)
        let window = LineWindowObservation(state: .captured, kind: .conversation, coverage: .contentExcludingChrome,
                                           windowID: 42, width: 500, height: 600, rows: rows,
                                           bodyCandidates: legacy, observedLabel: "Example conversation")
        let v2 = LineObservationService.snapshot(window, schemaVersion: 2)
        let v3 = LineObservationService.snapshot(window, schemaVersion: 3)
        XCTAssertNil(v2["conversationLabel"])
        XCTAssertNil(v2["annotations"])
        XCTAssertEqual((v2["bodyCandidates"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: v2["ocrSpans"]!, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: v3["ocrSpans"]!, options: [.sortedKeys]))
        XCTAssertEqual(v3["conversationLabel"] as? String, "Example conversation")
        XCTAssertEqual(v3["conversationLabelEvidence"] as? String, "ax_window_title")
        XCTAssertTrue(v3["conversationKey"] is NSNull)
        XCTAssertEqual(v3["identityConfidence"] as? String, "unknown")
        XCTAssertEqual(v3["tailCoverage"] as? Bool, false)
        let bodies = try XCTUnwrap(v3["bodyCandidates"] as? [[String: Any]])
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?["displayedTimeText"] as? String, "午後 1:23")
        XCTAssertTrue(bodies.first?["sender"] is NSNull)
        XCTAssertTrue(bodies.first?["fromSelf"] is NSNull)
        XCTAssertTrue(bodies.first?["sentAt"] is NSNull)
        let unavailable = LineObservationProtocol.snapshotsForWire([["scope": "selected_thread_visible_window", "coverage": "unavailable", "conversationLabel": "stale"]], schemaVersion: 3)[0]
        XCTAssertTrue(unavailable["conversationLabel"] is NSNull)
        XCTAssertEqual((unavailable["annotations"] as? [[String: Any]])?.count, 0)
    }
    func testV2FallbackSurfacesExplicitlyPreserveUnknownAttributionAndV1IsUnchanged() throws {
        let candidate: [String: Any] = ["ordinal": 0, "text": "sample", "spanOrdinals": [0]]
        let source: [[String: Any]] = [
            ["scope": "selected_thread_visible_window", "coverage": "available", "ocrSpans": [], "bodyCandidates": [candidate]],
            ["scope": "selected_thread_visible_window", "coverage": "unavailable", "reason": "screen_locked", "ocrSpans": []],
            ["scope": "notification_visible_window", "coverage": "unavailable", "ocrSpans": []],
            ["scope": "state", "coverage": "unavailable", "ocrSpans": []]
        ]
        let legacy = LineObservationProtocol.snapshotsForWire(source, schemaVersion: 1)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys]))
        let v2 = LineObservationProtocol.snapshotsForWire(source, schemaVersion: 2)
        for snapshot in v2 {
            XCTAssertTrue(snapshot["conversationKey"] is NSNull)
            XCTAssertEqual(snapshot["identityConfidence"] as? String, "unknown")
            XCTAssertEqual(snapshot["tailCoverage"] as? Bool, false)
            XCTAssertNotNil(snapshot["bodyCandidates"] as? [[String: Any]])
        }
        XCTAssertEqual((v2[0]["bodyCandidates"] as? [[String: Any]])?.first?["text"] as? String, "sample")
        for snapshot in v2.dropFirst() {
            XCTAssertEqual((snapshot["bodyCandidates"] as? [[String: Any]])?.count, 0)
        }
        XCTAssertNil(source[1]["conversationKey"])
    }

    func testUpgradeRequiresExplicitCompatibleAdvertisement() throws {
        func version(_ value: [String: Any]) throws -> Int {
            LineObservationProtocol.supportedVersion(capabilityData: try JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertEqual(try version(["ok": true, "supportedSchemaVersions": [1, 2],
                                    "bodyCandidateFormat": "line-body-candidate-v1"]), 2)
        XCTAssertEqual(try version(["ok": true, "supportedSchemaVersions": [1]]), 1)
        XCTAssertEqual(try version(["ok": true, "supportedSchemaVersions": [2],
                                    "bodyCandidateFormat": "other"]), 1)
        XCTAssertEqual(try version(["ok": false, "supportedSchemaVersions": [2],
                                    "bodyCandidateFormat": "line-body-candidate-v1"]), 1)
        XCTAssertEqual(LineObservationProtocol.supportedVersion(capabilityData: Data("not-json".utf8)), 1)
    }
}
