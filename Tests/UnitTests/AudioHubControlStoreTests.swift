import Foundation
import XCTest
@testable import ClawGate

final class AudioHubControlStoreTests: XCTestCase {
    private let source = "00000000-0000-4000-8000-000000000001"

    func testAdmissionAndClockGapAreDurableDistinctFromDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try AudioHubOutbox(directory: root.appendingPathComponent("outbox"), maxMetadataBytes: 32_000, sourceUUID: source)
        let controlRoot = root.appendingPathComponent("control")
        let control = try AudioHubControlStore(directory: controlRoot, sourceUUID: source, maxControlBytes: 8_000)
        let valid = try AudioHubTranscriptWire.prepare(raw: Data("{\"text\":\"literal\",\"capturedAt\":1700000000}\n".utf8), sourceSessionID: "example", line: 1)
        let gap = try AudioHubTranscriptWire.prepare(raw: Data("{\"text\":\"private gap text\"}\n".utf8), sourceSessionID: "example", line: 2)
        let admitted = try control.admit(valid, into: outbox)
        XCTAssertEqual(admitted.disposition, "enqueued")
        XCTAssertEqual(try control.admit(valid, into: outbox), admitted)
        let excluded = try control.admit(gap, into: outbox)
        XCTAssertEqual(excluded.reason, "source_clock_unknown")
        XCTAssertNil(excluded.externalID)
        XCTAssertEqual(try outbox.pending(limit: 10).count, 1)
        let reopened = try AudioHubControlStore(directory: controlRoot, sourceUUID: source, maxControlBytes: 8_000)
        XCTAssertEqual(try reopened.checkpoints(), [admitted, excluded])
        let bytes = try Data(contentsOf: controlRoot.appendingPathComponent("control.json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private gap text"))
    }

    func testControlCapacityFailureDoesNotAdvanceOrEnqueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try AudioHubOutbox(directory: root.appendingPathComponent("outbox"), maxMetadataBytes: 32_000, sourceUUID: source)
        let control = try AudioHubControlStore(directory: root.appendingPathComponent("control"), sourceUUID: source, maxControlBytes: 150)
        for raw in ["{\"text\":\"a\",\"capturedAt\":1700000000}", "{\"text\":\"a\"}"] {
            let prepared = try AudioHubTranscriptWire.prepare(raw: Data(raw.utf8), sourceSessionID: "example", line: 1)
            XCTAssertThrowsError(try control.admit(prepared, into: outbox)) { XCTAssertEqual($0 as? AudioHubControlStore.Failure, .capacityExceeded) }
        }
        XCTAssertTrue(try control.checkpoints().isEmpty)
        XCTAssertTrue(try outbox.pending(limit: 10).isEmpty)
    }

    func testOutboxFailureDoesNotRecordAdmissionAndReplayReusesAlreadyQueuedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outboxRoot = root.appendingPathComponent("outbox")
        let control = try AudioHubControlStore(directory: root.appendingPathComponent("control"), sourceUUID: source, maxControlBytes: 8_000)
        let small = try AudioHubOutbox(directory: outboxRoot, maxMetadataBytes: 150, sourceUUID: source)
        let prepared = try AudioHubTranscriptWire.prepare(raw: Data("{\"text\":\"a\",\"capturedAt\":1700000000}".utf8), sourceSessionID: "example", line: 1)
        XCTAssertThrowsError(try control.admit(prepared, into: small))
        XCTAssertTrue(try control.checkpoints().isEmpty)
        let recovered = try AudioHubOutbox(directory: outboxRoot, maxMetadataBytes: 32_000, sourceUUID: source)
        // Simulate the queue-write succeeding before a prior journal write was interrupted.
        let id = try recovered.enqueue(sourceRecordRef: prepared.sourceRecordRef, revision: prepared.revisionRef) { uuid, id in
            try XCTUnwrap(prepared.envelope(sourceUUID: uuid, externalID: id))
        }
        let original = try XCTUnwrap(recovered.pending(limit: 1).first?.envelope)
        XCTAssertEqual(try control.admit(prepared, into: recovered).externalID, id)
        XCTAssertEqual(try recovered.pending(limit: 10).count, 1)
        XCTAssertEqual(try recovered.pending(limit: 1).first?.envelope, original)
    }

    func testJournalIOFailureRetainsQueueAndRequiresReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try AudioHubOutbox(directory: root.appendingPathComponent("outbox"), maxMetadataBytes: 32_000, sourceUUID: source)
        let directory = root.appendingPathComponent("control")
        let backup = root.appendingPathComponent("control-backup")
        let control = try AudioHubControlStore(directory: directory, sourceUUID: source, maxControlBytes: 8_000)
        let prepared = try AudioHubTranscriptWire.prepare(raw: Data("{\"text\":\"a\",\"capturedAt\":1700000000}".utf8), sourceSessionID: "example", line: 1)
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data().write(to: directory) // Make the journal path unwritable, not the outbox.
        XCTAssertThrowsError(try control.admit(prepared, into: outbox))
        XCTAssertEqual(try outbox.pending(limit: 10).count, 1)
        XCTAssertThrowsError(try control.checkpoints()) { XCTAssertEqual($0 as? AudioHubControlStore.Failure, .storageFailed) }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        let reopened = try AudioHubControlStore(directory: directory, sourceUUID: source, maxControlBytes: 8_000)
        XCTAssertTrue(try reopened.checkpoints().isEmpty)
        _ = try reopened.admit(prepared, into: outbox)
        XCTAssertEqual(try outbox.pending(limit: 10).count, 1)
        XCTAssertEqual(try reopened.checkpoints().count, 1)
    }
}
