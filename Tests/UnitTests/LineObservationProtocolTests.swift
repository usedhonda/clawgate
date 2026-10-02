import XCTest
@testable import ClawGate

final class LineObservationProtocolTests: XCTestCase {
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
