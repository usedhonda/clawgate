import XCTest
@testable import ClawGate

final class HubProducerProvisionTests: XCTestCase {
    private func provision(_ overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["schema_version": 1, "source": "line", "base_url": "https://hub.example.invalid/",
                                    "bearer_token": "fixture-only", "allowed_domains": ["line"]]
        value.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }

    func testSourceBoundProvisionAndSafeFile() throws {
        let parsed = try HubProducerProvision.parse(provision(), source: "line")
        XCTAssertEqual(parsed.endpoint("v1/events").absoluteString, "https://hub.example.invalid/v1/events")
        for changes: [String: Any] in [["source": "clawgate"], ["allowed_domains": ["messages"]],
                                      ["base_url": "http://hub.example.invalid/"], ["base_url": "https://u:p@hub.example.invalid/"],
                                      ["base_url": "https://hub.example.invalid/path"], ["bearer_token": "bad\nheader"]] {
            XCTAssertThrowsError(try HubProducerProvision.parse(provision(changes), source: "line"))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("line.json")
        XCTAssertNil(try HubProducerProvision.load(source: "line", from: file))
        try provision().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try HubProducerProvision.load(source: "line", from: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertNotNil(try HubProducerProvision.load(source: "line", from: file))
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try HubProducerProvision.load(source: "line", from: link))
    }

    func testMetadataReceiptRejectsWrongSourceOriginalAndMalformedIdentity() throws {
        var receipt: [String: Any] = ["receipt_version": 1, "source": "line", "external_id": "line:fixture:1",
            "event_id": "00000000-0000-4000-8000-000000000001", "sha256": NSNull(), "byte_length": 0, "ingest_sequence": 1]
        func validate(_ value: [String: Any]) throws -> Data {
            try HubMetadataReceipt.validatedData(response: JSONSerialization.data(withJSONObject: ["storage_receipt": value]),
                                                 source: "line", externalID: "line:fixture:1")
        }
        XCTAssertFalse(try validate(receipt).isEmpty)
        for (key, value): (String, Any) in [("source", "chrome"), ("external_id", "other"), ("event_id", "not-uuid"),
                                          ("byte_length", 1), ("sha256", String(repeating: "a", count: 64)), ("ingest_sequence", true)] {
            var wrong = receipt; wrong[key] = value
            XCTAssertThrowsError(try validate(wrong))
        }
        receipt.removeValue(forKey: "sha256")
        XCTAssertThrowsError(try validate(receipt))
    }

    func testLineEnvelopeKeepsUnknownMetadataAndSourceClock() throws {
        let raw: [String: Any] = ["schemaVersion": 2, "observationId": "line:fixture:1", "platform": "line",
            "source": "clawgate-line-passive-ocr", "capturedAt": "2026-01-01T00:00:00.123Z",
            "snapshots": [["identityConfidence": "unknown", "sender": NSNull(), "bodyCandidates": []]]]
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        let wire = try LineObservationProtocol.hubEnvelope(observation: data, observationID: "line:fixture:1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "line")
        XCTAssertEqual(object["domain"] as? String, "line")
        XCTAssertEqual(object["kind"] as? String, "passive-observation")
        XCTAssertEqual(object["occurred_at"] as? String, raw["capturedAt"] as? String)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(object["metadata"]), options: [.sortedKeys]), data)
        XCTAssertThrowsError(try LineObservationProtocol.hubEnvelope(observation: data, observationID: "different"))
    }
}
