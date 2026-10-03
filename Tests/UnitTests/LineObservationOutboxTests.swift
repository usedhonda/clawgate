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

    func testHubEnvelopeIsStableAndRawRecordRemainsUnchangedAcrossReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try LineObservationOutbox(directory: directory, maxBytes: 64)
        let raw = Data([0x11, 0x22, 0x33])
        try outbox.enqueue(raw, observationID: "observation")
        var makeCalls = 0
        let first = try outbox.hubEnvelope(observationID: "observation") { input in
            makeCalls += 1
            return input + Data([0x44])
        }
        let second = try outbox.hubEnvelope(observationID: "observation") { _ in
            makeCalls += 1
            return Data([0xff])
        }
        XCTAssertEqual(first, second)
        XCTAssertEqual(makeCalls, 1)
        let reopened = try LineObservationOutbox(directory: directory, maxBytes: 64)
        let third = try reopened.hubEnvelope(observationID: "observation") { _ in
            XCTFail("persisted envelope must not be rebuilt")
            return Data()
        }
        XCTAssertEqual(third, first)
        XCTAssertEqual(try reopened.pending().first?.data, raw)
    }

    func testHubEnvelopeCountsAgainstCapacity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try LineObservationOutbox(directory: directory, maxBytes: 4)
        try outbox.enqueue(Data([1, 2]), observationID: "observation")
        XCTAssertThrowsError(try outbox.hubEnvelope(observationID: "observation") { _ in Data([3, 4, 5]) })
        XCTAssertEqual(outbox.queuedBytes, 2)
    }

    func testHubSelectionAndReceiptPersistAcrossReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try LineObservationOutbox(directory: directory)
        try outbox.selectIndependentHub()
        try outbox.enqueue(Data([7]), observationID: "observation")
        try outbox.acknowledgeHub("observation", receipt: Data([8, 9]))
        let reopened = try LineObservationOutbox(directory: directory)
        XCTAssertTrue(reopened.independentHubSelected)
        XCTAssertEqual(reopened.lastHubReceipt, Data([8, 9]))
        XCTAssertEqual(reopened.queuedCount, 0)
    }
}
