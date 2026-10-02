import XCTest
@testable import ClawGate

final class LineObservationOutboxTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("line-observation-outbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDurabilityFIFOAndDeduplicationAcrossReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LineObservationOutbox(directory: directory)
        let allocated = try first.allocateID()
        try first.enqueue(Data("one".utf8), observationID: allocated.id)
        try first.enqueue(Data("one".utf8), observationID: allocated.id)
        XCTAssertThrowsError(try first.enqueue(Data("one-again".utf8), observationID: allocated.id))
        try first.enqueue(Data("two".utf8), observationID: "observation-2")
        XCTAssertEqual(first.queuedCount, 2)

        let reopened = try LineObservationOutbox(directory: directory)
        let pending = try reopened.pending()
        XCTAssertEqual(pending.map(\.id), [allocated.id, "observation-2"])
        XCTAssertEqual(pending.map { String(decoding: $0.data, as: UTF8.self) }, ["one", "two"])
        let next = try reopened.allocateID()
        XCTAssertEqual(next.seq, allocated.seq + 2)
    }

    func testCapacityAndAcknowledgementValidation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try LineObservationOutbox(directory: directory, maxBytes: 3)
        XCTAssertThrowsError(try outbox.enqueue(Data("1234".utf8), observationID: "too-large"))
        try outbox.enqueue(Data("123".utf8), observationID: "known")
        XCTAssertThrowsError(try outbox.acknowledge(["unknown"]))
        try outbox.acknowledge(["known"])
        XCTAssertEqual(outbox.queuedBytes, 0)
    }

    func testInvalidIdentifiersCannotEscapeDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try LineObservationOutbox(directory: directory)
        XCTAssertThrowsError(try outbox.enqueue(Data(), observationID: "../escape"))
        XCTAssertThrowsError(try outbox.enqueue(Data(), observationID: "nested/path"))
    }
}
