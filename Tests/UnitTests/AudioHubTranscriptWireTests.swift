import Foundation
import CryptoKit
import XCTest
@testable import ClawGate

final class AudioHubTranscriptWireTests: XCTestCase {
    private let sourceUUID = "00000000-0000-4000-8000-000000000051"

    func testPreservesRawAttributesTextPrivacyAndReferences() throws {
        let raw = Data((#"{"capturedAt":1700000000,"text":"  exact\ntext  ","privacy_flags":{"redact":true},"speaker":"self","extra":7}"# + "\n").utf8)
        let prepared = try AudioHubTranscriptWire.prepare(raw: raw, sourceSessionID: "session-1", line: 1)
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(prepared.revisionRef, "sha256:\(digest)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try AudioHubOutbox(directory: root, maxMetadataBytes: 32_000, sourceUUID: sourceUUID)
        let externalID = try outbox.enqueue(sourceRecordRef: prepared.sourceRecordRef, revision: prepared.revisionRef) { uuid, id in
            try XCTUnwrap(prepared.envelope(sourceUUID: uuid, externalID: id))
        }
        let provisional = try XCTUnwrap(try outbox.pending(limit: 1).first?.envelope)
        let reopened = try AudioHubOutbox(directory: root, maxMetadataBytes: 32_000, sourceUUID: sourceUUID)
        XCTAssertEqual(try reopened.pending(limit: 1).first?.externalID, externalID)
        XCTAssertEqual(try reopened.pending(limit: 1).first?.envelope, provisional)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: provisional) as? [String: Any])
        let metadata = try XCTUnwrap(value["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["text"] as? String, "  exact\ntext  ")
        XCTAssertEqual((metadata["privacy_flags"] as? [String: Any])?["redact"] as? Bool, true)
        XCTAssertEqual(metadata["session_id"] as? String, "clawgate:session:session-1")
        XCTAssertEqual(metadata["schema_version"] as? Int, 1)
        XCTAssertEqual(metadata["source_uuid"] as? String, sourceUUID)
        XCTAssertEqual((metadata["raw_segment"] as? [String: Any])?["extra"] as? Int, 7)
        XCTAssertEqual((metadata["privacy_flags"] as? [String: Any])?["redact"] as? Bool, true)
        let missingPrivacy = try AudioHubTranscriptWire.prepare(raw: Data(#"{"capturedAt":1700000000,"text":"x"}"#.utf8), sourceSessionID: "session-1", line: 2)
        let missingEnvelope = try XCTUnwrap(try missingPrivacy.envelope(sourceUUID: sourceUUID, externalID: AudioHubOutbox.externalID(sourceUUID: sourceUUID, sourceRecordRef: missingPrivacy.sourceRecordRef, revision: missingPrivacy.revisionRef)))
        let missingMetadata = try XCTUnwrap((JSONSerialization.jsonObject(with: missingEnvelope) as? [String: Any])?["metadata"] as? [String: Any])
        XCTAssertTrue(missingMetadata["privacy_flags"] is NSNull)
        XCTAssertEqual(metadata["speaker_identity_confidence"] as? String, "unverified")
        XCTAssertEqual(value["occurred_at"] as? String, "2023-11-14T22:13:20Z")
    }

    func testUnknownClockProducesBodyFreeGap() throws {
        for raw in [
            #"{"capturedAt":null,"text":"x"}"#,
            #"{"capturedAt":true,"text":"x"}"#,
            #"{"text":"x"}"#,
            #"{"capturedAt":1e30,"text":"x"}"#
        ] {
            let prepared = try AudioHubTranscriptWire.prepare(raw: Data(raw.utf8), sourceSessionID: "s", line: 2)
            XCTAssertTrue(prepared.isGap)
            let gap = try XCTUnwrap(try prepared.controlGap())
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: gap) as? [String: Any])
            XCTAssertNil(try prepared.envelope(sourceUUID: sourceUUID, externalID: "unused"))
            XCTAssertEqual(object["reason"] as? String, "source_clock_unknown")
            XCTAssertEqual(object["coverage"] as? String, "excluded")
            XCTAssertEqual(Set(object.keys), Set(["source_record_ref", "revision_ref", "reason", "coverage"]))
        }
    }

    func testRejectsMalformedInputsAndAmbiguousReferences() {
        XCTAssertThrowsError(try AudioHubTranscriptWire.prepare(raw: Data("not json".utf8), sourceSessionID: "s", line: 1))
        XCTAssertThrowsError(try AudioHubTranscriptWire.prepare(raw: Data(#"{"capturedAt":1,"text":3}"#.utf8), sourceSessionID: "s", line: 1))
        XCTAssertThrowsError(try AudioHubTranscriptWire.prepare(raw: Data(#"{"capturedAt":1,"text":"x"}"#.utf8), sourceSessionID: "bad:id", line: 1))
        XCTAssertThrowsError(try AudioHubTranscriptWire.prepare(raw: Data(#"{"capturedAt":1,"text":"x"}"#.utf8), sourceSessionID: "s", line: 0))
    }

}
