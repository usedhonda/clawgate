import XCTest
import Darwin
@testable import ClawGate

final class AudioHubTranscriptScannerTests: XCTestCase {
    private let source = "00000000-0000-4000-8000-000000000001"
    private let session = "example"
    private var root: URL!
    private var rawURL: URL { root.appendingPathComponent("sessions/example/transcripts/raw.jsonl") }
    private var sessions: URL { root.appendingPathComponent("sessions") }
    private var queueRoot: URL { root.appendingPathComponent("queue") }
    private var controlRoot: URL { root.appendingPathComponent("control") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func initial(_ text: String) throws -> AudioHubRawTranscriptReader.Checkpoint {
        try Data(text.utf8).write(to: rawURL)
        var info = stat(); XCTAssertEqual(lstat(rawURL.path, &info), 0)
        return .init(offset: 0, physicalLine: 0,
            snapshot: .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), length: UInt64(info.st_size)))
    }
    private func outbox(_ budget: Int = 32_000) throws -> AudioHubOutbox {
        try AudioHubOutbox(directory: queueRoot, maxMetadataBytes: budget, sourceUUID: source)
    }
    private func control(_ budget: Int = 16_000) throws -> AudioHubControlStore {
        try AudioHubControlStore(directory: controlRoot, sourceUUID: source, maxControlBytes: budget)
    }
    private func scanner(_ checkpoint: AudioHubRawTranscriptReader.Checkpoint,
                         _ journal: AudioHubControlStore, _ queue: AudioHubOutbox) throws -> AudioHubTranscriptScanner {
        try AudioHubTranscriptScanner(sessionsRoot: sessions, sessionID: session,
            initialCheckpoint: checkpoint, control: journal, outbox: queue, maxReadBytes: 4096, maxLineBytes: 4096)
    }

    func testCrashStopsConvergeToFrozenBytesAndSameID() throws {
        let first = "{\"text\":\"first\",\"capturedAt\":1700000000}\r\n"
        let second = "{\"text\":\"clock unknown\"}\n"
        let start = try initial(first + second)
        var queue = try outbox(); var journal = try control()
        var scan = try scanner(start, journal, queue)
        guard case .line(let frozen) = try scan.stageNext() else { return XCTFail("missing staged line") }
        XCTAssertEqual(frozen.rawLine, Data(first.utf8))
        XCTAssertEqual(try journal.scan(sessionID: session).cursor.offset, 0)

        // Queue commit followed by crash before admission journal commit.
        let prepared = try AudioHubTranscriptWire.prepare(raw: frozen.rawLine, sourceSessionID: session, line: 1)
        let id = try queue.enqueue(sourceRecordRef: prepared.sourceRecordRef, revision: prepared.revisionRef) { uuid, id in
            try XCTUnwrap(prepared.envelope(sourceUUID: uuid, externalID: id))
        }
        let bytes = try XCTUnwrap(queue.pending(limit: 1).first?.envelope)
        // A same-inode rewrite is outside reader detection. Recovery must
        // nevertheless use already staged bytes, never replace their identity.
        let handle = try FileHandle(forWritingTo: rawURL)
        try handle.write(contentsOf: Data(first.replacingOccurrences(of: "first", with: "later").utf8)); try handle.close()
        queue = try outbox(); journal = try control(); scan = try scanner(start, journal, queue)
        guard case .admitted(let admitted) = try scan.step() else { return XCTFail("not admitted") }
        XCTAssertEqual(admitted.externalID, id)
        XCTAssertEqual(try queue.pending(limit: 10).count, 1)
        XCTAssertEqual(try queue.pending(limit: 1).first?.envelope, bytes)
        XCTAssertEqual(try journal.scan(sessionID: session).cursor.offset, UInt64(first.utf8.count))

        // Exclusion journal commit followed by crash before cursor commit.
        guard case .line(let gapLine) = try scan.stageNext() else { return XCTFail("missing gap") }
        let gap = try AudioHubTranscriptWire.prepare(raw: gapLine.rawLine, sourceSessionID: session, line: 2)
        let excluded = try journal.admit(gap, into: queue)
        journal = try control(); queue = try outbox(); scan = try scanner(start, journal, queue)
        XCTAssertEqual(try scan.step(), .admitted(excluded))
        XCTAssertEqual(excluded.reason, "source_clock_unknown")
        XCTAssertEqual(try journal.scan(sessionID: session).cursor.physicalLine, 2)
        XCTAssertEqual(try scan.step(), .endOfFile)
        XCTAssertEqual(try queue.pending(limit: 10).count, 1)
    }

    func testQueueCapacityFailureHoldsStagedLineAndCursor() throws {
        let start = try initial("{\"text\":\"literal\",\"capturedAt\":1700000000}\n")
        var journal = try control(); let small = try outbox(150)
        var scan = try scanner(start, journal, small)
        XCTAssertThrowsError(try scan.step())
        let held = try journal.scan(sessionID: session)
        XCTAssertEqual(held.cursor.offset, 0); XCTAssertNotNil(held.staged)
        XCTAssertTrue(try journal.checkpoints().isEmpty)
        journal = try control(); let recovered = try outbox(); scan = try scanner(start, journal, recovered)
        guard case .admitted = try scan.step() else { return XCTFail("not recovered") }
        XCTAssertEqual(try recovered.pending(limit: 10).count, 1)
    }

    func testControlBudgetIsSharedWithStagedBytesAndNoImplicitStart() throws {
        let start = try initial("{\"text\":\"literal\",\"capturedAt\":1700000000}\n")
        let queue = try outbox(); var journal = try control()
        _ = try scanner(start, journal, queue)
        let size = try Data(contentsOf: controlRoot.appendingPathComponent("control.json")).count
        journal = try control(size + 8)
        let scan = try scanner(start, journal, queue)
        XCTAssertThrowsError(try scan.step()) { XCTAssertEqual($0 as? AudioHubControlStore.Failure, .capacityExceeded) }
        XCTAssertNil(try journal.scan(sessionID: session).staged)
        XCTAssertTrue(try queue.pending(limit: 10).isEmpty)
        XCTAssertThrowsError(try scanner(.init(), journal, queue))
        let changed = AudioHubRawTranscriptReader.Checkpoint(offset: start.snapshot!.length, physicalLine: 1, snapshot: start.snapshot)
        XCTAssertThrowsError(try scanner(changed, journal, queue))
    }

    func testAckBeforeCursorRecoveryDoesNotReenqueue() throws {
        let start = try initial("{\"text\":\"literal\",\"capturedAt\":1700000000}\n")
        var queue = try outbox(); var journal = try control(); var scan = try scanner(start, journal, queue)
        guard case .line(let line) = try scan.stageNext() else { return XCTFail("missing line") }
        let prepared = try AudioHubTranscriptWire.prepare(raw: line.rawLine, sourceSessionID: session, line: 1)
        let admitted = try journal.admit(prepared, into: queue)
        let record = try XCTUnwrap(queue.pending(limit: 1).first)
        let receipt = try JSONSerialization.data(withJSONObject: ["storage_receipt": [
            "receipt_version": 1, "source": "clawgate", "external_id": record.externalID,
            "event_id": "00000000-0000-4000-8000-000000000002", "sha256": NSNull(),
            "byte_length": 0, "ingest_sequence": 1]])
        let ack = try HubAudioAdmission.validate(response: receipt, externalID: record.externalID, sha256: nil, byteLength: 0, pipeline: nil)
        try queue.acknowledge(externalID: record.externalID, expectedEnvelope: record.envelope, receipt: ack.storageReceipt)
        queue = try outbox(); journal = try control(); scan = try scanner(start, journal, queue)
        XCTAssertEqual(try scan.step(), .admitted(admitted))
        XCTAssertTrue(try queue.pending(limit: 10).isEmpty)
        XCTAssertEqual(try journal.scan(sessionID: session).cursor.physicalLine, 1)
    }

    func testRotationAndStaleControlWriterCannotAdvance() throws {
        let text = "{\"text\":\"literal\",\"capturedAt\":1700000000}\n"
        let start = try initial(text); let queue = try outbox(); let journal = try control()
        let scan = try scanner(start, journal, queue)
        let stale = try control(); let staleScan = try scanner(start, stale, queue)
        _ = try scan.stageNext()
        XCTAssertThrowsError(try staleScan.stageNext()) { XCTAssertEqual($0 as? AudioHubControlStore.Failure, .staleWriter) }
        guard case .admitted = try scan.step() else { return XCTFail("not admitted") }
        try FileManager.default.moveItem(at: rawURL, to: rawURL.appendingPathExtension("old"))
        try Data(text.utf8).write(to: rawURL)
        XCTAssertThrowsError(try scan.step()) { XCTAssertEqual($0 as? AudioHubRawTranscriptReader.Error, .staleCursor) }
        XCTAssertEqual(try journal.scan(sessionID: session).cursor.physicalLine, 1)
    }
}
