import XCTest
@testable import ClawGate

final class AudioHubTranscriptDeliveryTests: XCTestCase {
    private func makeOutbox() throws -> (AudioHubOutbox, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-\(UUID().uuidString)")
        let source = "11111111-1111-1111-1111-111111111111"
        return (try AudioHubOutbox(directory: dir, maxMetadataBytes: 64 * 1024, sourceUUID: source), dir)
    }

    private func enqueue(_ outbox: AudioHubOutbox) throws {
        _ = try outbox.enqueue(sourceRecordRef: "clawgate:session:test:raw:1", revision: "sha256:" + String(repeating: "a", count: 64)) { _, _ in
            Data("immutable-body".utf8)
        }
    }

    private func acknowledgement(for record: AudioHubOutbox.PendingRecord) throws -> HubAudioAdmission.Acknowledgement {
        let storage: [String: Any] = [
            "receipt_version": 1, "source": "clawgate", "external_id": record.externalID,
            "event_id": "22222222-2222-2222-2222-222222222222", "sha256": NSNull(),
            "byte_length": 0, "ingest_sequence": 1
        ]
        let response = try JSONSerialization.data(withJSONObject: ["storage_receipt": storage])
        return try HubAudioAdmission.validate(response: response, externalID: record.externalID,
                                              sha256: nil, byteLength: 0, pipeline: nil)
    }

    private func acknowledgement(externalID: String) throws -> HubAudioAdmission.Acknowledgement {
        let storage: [String: Any] = [
            "receipt_version": 1, "source": "clawgate", "external_id": externalID,
            "event_id": "22222222-2222-2222-2222-222222222222", "sha256": NSNull(),
            "byte_length": 0, "ingest_sequence": 1
        ]
        let response = try JSONSerialization.data(withJSONObject: ["storage_receipt": storage])
        return try HubAudioAdmission.validate(response: response, externalID: externalID,
                                              sha256: nil, byteLength: 0, pipeline: nil)
    }

    func testSyntheticReceiptDequeuesOnlyMatchingPendingRecord() async throws {
        let (outbox, dir) = try makeOutbox(); defer { try? FileManager.default.removeItem(at: dir) }
        try enqueue(outbox)
        let delivery = AudioHubTranscriptDelivery(outbox: outbox) { record in
            try self.acknowledgement(for: record)
        }
        let delivered = try await delivery.deliverOne()
        XCTAssertNotNil(delivered)
        XCTAssertTrue(try outbox.pending(limit: 10).isEmpty)
    }

    func testSenderFailureLeavesImmutablePendingRecord() async throws {
        let (outbox, dir) = try makeOutbox(); defer { try? FileManager.default.removeItem(at: dir) }
        try enqueue(outbox)
        let before = try XCTUnwrap(outbox.pending(limit: 1).first)
        let delivery = AudioHubTranscriptDelivery(outbox: outbox) { _ in
            throw AudioHubMetadataTransport.Failure.transport
        }
        await assertThrowsAsync { try await delivery.deliverOne() }
        let after = try XCTUnwrap(outbox.pending(limit: 1).first)
        XCTAssertEqual(after, before)
    }

    func testWrongReceiptExternalIDRetainsPendingRecord() async throws {
        let (outbox, dir) = try makeOutbox(); defer { try? FileManager.default.removeItem(at: dir) }
        try enqueue(outbox)
        let delivery = AudioHubTranscriptDelivery(outbox: outbox) { _ in
            try self.acknowledgement(externalID: "wrong")
        }
        await assertThrowsAsync { try await delivery.deliverOne() }
        XCTAssertEqual(try outbox.pending(limit: 1).count, 1)
    }

    func testOriginalReferenceIsNotSent() async throws {
        let (outbox, dir) = try makeOutbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m1/audio/a.wav",
                                                             sha256: String(repeating: "a", count: 64), byteLength: 1)
        _ = try outbox.enqueue(sourceRecordRef: "original", revision: "rev", original: original) { _, _ in Data("body".utf8) }
        let sent = Flag()
        let delivery = AudioHubTranscriptDelivery(outbox: outbox) { _ in
            sent.value = true
            throw AudioHubMetadataTransport.Failure.transport
        }
        await assertThrowsAsync { try await delivery.deliverOne() }
        XCTAssertFalse(sent.value)
        XCTAssertEqual(try outbox.pending(limit: 1).count, 1)
    }

    func testStaleInstanceCannotReintroduceAcknowledgedRows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = "11111111-1111-1111-1111-111111111111"
        let first = try AudioHubOutbox(directory: dir, maxMetadataBytes: 64 * 1024, sourceUUID: source)
        let stale = try AudioHubOutbox(directory: dir, maxMetadataBytes: 64 * 1024, sourceUUID: source)
        try enqueue(first)
        let delivery = AudioHubTranscriptDelivery(outbox: first) { record in try self.acknowledgement(for: record) }
        _ = try await delivery.deliverOne()
        XCTAssertThrowsError(try stale.enqueue(sourceRecordRef: "new", revision: "rev") { _, _ in Data("x".utf8) }) {
            XCTAssertEqual($0 as? AudioHubOutbox.Error, .conflict)
        }
        let reopened = try AudioHubOutbox(directory: dir, maxMetadataBytes: 64 * 1024, sourceUUID: source)
        XCTAssertTrue(try reopened.pending(limit: 10).isEmpty)
    }
}

private final class Flag {
    var value = false
}

private func assertThrowsAsync<T>(_ expression: @escaping () async throws -> T) async {
    do { _ = try await expression(); XCTFail("expected error") } catch { }
}
