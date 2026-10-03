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
        let evidence = try XCTUnwrap(v3["conversationLabelEvidence"] as? [String: Any])
        XCTAssertEqual(evidence["method"] as? String, "ax_window_title")
        XCTAssertEqual(evidence["axObservationOrdinal"] as? Int, 0)
        let ax = try XCTUnwrap(v3["axObservations"] as? [[String: Any]])
        XCTAssertEqual(ax.first?["windowId"] as? String, "42")
        XCTAssertEqual(ax.first?["value"] as? String, v3["conversationLabel"] as? String)
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
        XCTAssertEqual((unavailable["axObservations"] as? [[String: Any]])?.count, 0)
    }

    private func fixture() throws -> [String: Any] {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/line-observation-v3.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    }

    func testV3FixtureRoundTripsWithoutChangingEnvelope() throws {
        let envelope = try fixture()
        let metadata = try XCTUnwrap(envelope["metadata"] as? [String: Any])
        let result = try LineObservationProtocol.boundedV3Observation(metadata)
        XCTAssertFalse(result.limited)
        XCTAssertEqual(try LineObservationProtocol.hubEnvelope(observation: result.data, observationID: metadata["observationId"] as! String),
                       try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]))
    }

    func testV3InvalidEvidenceAndExceededBoundsBecomeExplicitUnavailable() throws {
        let metadata = try XCTUnwrap(try fixture()["metadata"] as? [String: Any])
        let snapshot = try XCTUnwrap((metadata["snapshots"] as? [[String: Any]])?.first)
        var missingEvidence = snapshot
        missingEvidence.removeValue(forKey: "conversationLabelEvidence")
        var wrongWindow = snapshot
        var ax = snapshot["axObservations"] as! [[String: Any]]
        ax[0]["windowId"] = "different-window"
        wrongWindow["axObservations"] = ax
        var longSpan = snapshot
        var spans = snapshot["ocrSpans"] as! [[String: Any]]
        spans[0]["text"] = String(repeating: "😀", count: 2001)
        longSpan["ocrSpans"] = spans
        var manySpans = snapshot
        manySpans["ocrSpans"] = Array(repeating: spans[0], count: 501)
        var duplicateReference = snapshot
        var bodies = snapshot["bodyCandidates"] as! [[String: Any]]
        bodies[0]["spanOrdinals"] = [0, 1, 2]
        duplicateReference["bodyCandidates"] = bodies
        // Valid per-field lengths but a complete envelope larger than 2 MiB.
        var largeSnapshot = snapshot
        largeSnapshot["conversationLabel"] = NSNull()
        largeSnapshot["conversationLabelEvidence"] = NSNull()
        largeSnapshot["axObservations"] = [] as [[String: Any]]
        largeSnapshot["annotations"] = [] as [[String: Any]]
        let text = String(repeating: "字", count: 4000)
        largeSnapshot["ocrSpans"] = (0..<100).map { ["ordinal": $0, "text": text] as [String: Any] }
        largeSnapshot["bodyCandidates"] = (0..<100).map { ordinal -> [String: Any] in
            var candidate = (snapshot["bodyCandidates"] as! [[String: Any]])[0]
            candidate["ordinal"] = ordinal
            candidate["text"] = text
            candidate["spanOrdinals"] = [ordinal]
            candidate["displayedTimeText"] = NSNull()
            candidate["displayedTimeEvidence"] = NSNull()
            return candidate
        }
        for snapshots in [[missingEvidence], [wrongWindow], [longSpan], [manySpans], [duplicateReference],
                          Array(repeating: snapshot, count: 33), [largeSnapshot]] {
            var input = metadata
            input["snapshots"] = snapshots
            let result = try LineObservationProtocol.boundedV3Observation(input)
            XCTAssertTrue(result.limited)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
            let output = try XCTUnwrap((value["snapshots"] as? [[String: Any]])?.first)
            XCTAssertEqual(output["coverage"] as? String, "unavailable")
            XCTAssertEqual(output["reason"] as? String, "observation_limits_exceeded")
            XCTAssertEqual((output["ocrSpans"] as? [[String: Any]])?.count, 0)
            XCTAssertEqual((value["state"] as? [String: Any])?["captureStatus"] as? String, "observation_limits_exceeded")
            XCTAssertEqual(value["observationId"] as? String, metadata["observationId"] as? String)
        }
    }

    func testV3ReferencesUseExplicitBodyOrdinalAndRejectInvalidGeometryOrLinks() throws {
        var metadata = try XCTUnwrap(try fixture()["metadata"] as? [String: Any])
        var snapshot = (metadata["snapshots"] as! [[String: Any]])[0]
        var bodies = snapshot["bodyCandidates"] as! [[String: Any]]
        var annotations = snapshot["annotations"] as! [[String: Any]]
        bodies[0]["ordinal"] = 4
        annotations[0]["relatedBodyOrdinal"] = 4
        snapshot["bodyCandidates"] = bodies
        snapshot["annotations"] = annotations
        metadata["snapshots"] = [snapshot]
        XCTAssertFalse(try LineObservationProtocol.boundedV3Observation(metadata).limited)
        for variant in 0..<4 {
            var invalid = snapshot
            var changedBodies = bodies
            var changedAnnotations = annotations
            switch variant {
            case 0: changedAnnotations[0]["relatedBodyOrdinal"] = 0 // array index is not the ordinal
            case 1: changedBodies[0]["x"] = Double.infinity
            case 2: changedAnnotations[0]["width"] = 1.1
            default: changedBodies[0]["displayedTimeEvidence"] = ["method": "ocr_clock_badge_layout", "spanOrdinals": [3]]
            }
            invalid["bodyCandidates"] = changedBodies
            invalid["annotations"] = changedAnnotations
            metadata["snapshots"] = [invalid]
            XCTAssertTrue(try LineObservationProtocol.boundedV3Observation(metadata).limited)
        }
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
