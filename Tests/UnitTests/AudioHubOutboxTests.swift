import Foundation
import XCTest
@testable import ClawGate

final class AudioHubOutboxTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testReopenPreservesSourceIDRecordAndBody() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try AudioHubOutbox(directory: root, maxMetadataBytes: 32_000, sourceUUID: "00000000-0000-4000-8000-000000000001")
        let id = try first.enqueue(sourceRecordRef: "meeting-1", revision: "r1") { _, externalID in
            Data("body:\(externalID)".utf8)
        }
        let second = try AudioHubOutbox(directory: root, maxMetadataBytes: 32_000, sourceUUID: "different")
        XCTAssertEqual(second.sourceUUID, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(try second.pending(limit: 10).first?.externalID, id)
        XCTAssertEqual(try second.pending(limit: 10).first?.envelope, Data("body:\(id)".utf8))
    }

    func testDuplicateIsIdempotentAndConflictRejected() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try AudioHubOutbox(directory: root, maxMetadataBytes: 32_000, sourceUUID: "00000000-0000-4000-8000-000000000002")
        let id = try outbox.enqueue(sourceRecordRef: "meeting-1", revision: "r1") { _, _ in Data("one".utf8) }
        XCTAssertEqual(try outbox.enqueue(sourceRecordRef: "meeting-1", revision: "r1") { _, _ in Data("one".utf8) }, id)
        XCTAssertThrowsError(try outbox.enqueue(sourceRecordRef: "meeting-1", revision: "r1") { _, _ in Data("two".utf8) }) { XCTAssertEqual($0 as? AudioHubOutbox.Error, .conflict) }
    }

    func testCapacityFailureRetainsQueue() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try AudioHubOutbox(directory: root, maxMetadataBytes: 240, sourceUUID: "00000000-0000-4000-8000-000000000003")
        XCTAssertThrowsError(try outbox.enqueue(sourceRecordRef: "meeting-1", revision: "r1") { _, _ in Data(repeating: 1, count: 500) }) { XCTAssertEqual($0 as? AudioHubOutbox.Error, .capacityExceeded) }
        XCTAssertTrue(try outbox.pending(limit: 10).isEmpty)
    }

    func testAcknowledgeMismatchRetainsPendingAndValidAckIsAtomic() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try AudioHubOutbox(directory: root, maxMetadataBytes: 32_000, sourceUUID: "00000000-0000-4000-8000-000000000004")
        let id = try outbox.enqueue(sourceRecordRef: "meeting-1", revision: "r1") { _, _ in Data("body".utf8) }
        XCTAssertThrowsError(try outbox.acknowledge(externalID: id, expectedEnvelope: Data("bad".utf8), receipt: Data("receipt".utf8))) { XCTAssertEqual($0 as? AudioHubOutbox.Error, .payloadMismatch) }
        XCTAssertEqual(try outbox.pending(limit: 10).count, 1)
        try outbox.acknowledge(externalID: id, expectedEnvelope: Data("body".utf8), receipt: Data("receipt".utf8))
        XCTAssertTrue(try outbox.pending(limit: 10).isEmpty)
        let reopened = try AudioHubOutbox(directory: root, maxMetadataBytes: 32_000, sourceUUID: "00000000-0000-4000-8000-000000000004")
        XCTAssertTrue(try reopened.pending(limit: 10).isEmpty)
    }

    func testOriginalReferenceRejectsRollingAndTraversal() throws {
        XCTAssertThrowsError(try AudioHubOutbox.OriginalReference(sourceRelativePath: "rolling/2026/chunk.wav", sha256: String(repeating: "a", count: 64), byteLength: 1))
        XCTAssertThrowsError(try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/../audio/file.m4a", sha256: String(repeating: "a", count: 64), byteLength: 1))
        XCTAssertNoThrow(try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/mtg-1/audio/file.m4a", sha256: String(repeating: "a", count: 64), byteLength: 1))
    }
}
