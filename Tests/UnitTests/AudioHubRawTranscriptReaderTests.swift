import XCTest
import Darwin
@testable import ClawGate

final class AudioHubRawTranscriptReaderTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-raw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rawURL(_ root: URL, _ session: String = "ctx-test") throws -> URL {
        let dir = root.appendingPathComponent(session).appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("raw.jsonl")
    }

    func testPreservesLFCRLFAndPhysicalBlankLineNumbers() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let file = try rawURL(r)
        try Data("first\r\n\nthird\n".utf8).write(to: file)
        var cp = AudioHubRawTranscriptReader.Checkpoint()
        guard case .line(let first) = try AudioHubRawTranscriptReader.read(
            sessionsRoot: r, sessionID: "ctx-test", checkpoint: cp, maxReadBytes: 100, maxLineBytes: 100) else {
            return XCTFail("first line not returned")
        }
        XCTAssertEqual(first.rawLine, Data("first\r\n".utf8)); XCTAssertEqual(first.physicalLine, 1)
        cp = .init(offset: first.nextOffset, physicalLine: first.nextPhysicalLine, snapshot: first.snapshot)
        guard case .line(let blank) = try AudioHubRawTranscriptReader.read(
            sessionsRoot: r, sessionID: "ctx-test", checkpoint: cp, maxReadBytes: 100, maxLineBytes: 100) else {
            return XCTFail("blank line not returned")
        }
        XCTAssertEqual(blank.rawLine, Data("\n".utf8)); XCTAssertEqual(blank.physicalLine, 2)
    }

    func testTornTailHeldUntilAppend() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let file = try rawURL(r); try Data("torn".utf8).write(to: file)
        XCTAssertEqual(try AudioHubRawTranscriptReader.read(sessionsRoot: r, sessionID: "ctx-test",
            checkpoint: .init(), maxReadBytes: 100, maxLineBytes: 100), .incompleteTail)
        let h = try FileHandle(forWritingTo: file); try h.seekToEnd(); try h.write(contentsOf: Data("\n".utf8)); try h.close()
        guard case .line(let line) = try AudioHubRawTranscriptReader.read(sessionsRoot: r, sessionID: "ctx-test",
            checkpoint: .init(), maxReadBytes: 100, maxLineBytes: 100) else { return XCTFail("appended tail not returned") }
        XCTAssertEqual(line.rawLine, Data("torn\n".utf8))
    }

    func testBoundsAreExplicitForLargeLine() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let file = try rawURL(r); try Data(repeating: 0x78, count: 12).write(to: file)
        XCTAssertThrowsError(try AudioHubRawTranscriptReader.read(sessionsRoot: r, sessionID: "ctx-test",
            checkpoint: .init(), maxReadBytes: 100, maxLineBytes: 8)) {
            XCTAssertEqual($0 as? AudioHubRawTranscriptReader.Error, .lineLimitExceeded)
        }
        XCTAssertThrowsError(try AudioHubRawTranscriptReader.read(sessionsRoot: r, sessionID: "ctx-test",
            checkpoint: .init(), maxReadBytes: 4, maxLineBytes: 100)) {
            XCTAssertEqual($0 as? AudioHubRawTranscriptReader.Error, .readLimitExceeded)
        }
    }

    func testReplacementAndTruncationRejectSavedCursor() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let file = try rawURL(r); try Data("one\ntwo\n".utf8).write(to: file)
        guard case .line(let line) = try AudioHubRawTranscriptReader.read(sessionsRoot: r, sessionID: "ctx-test",
            checkpoint: .init(), maxReadBytes: 100, maxLineBytes: 100) else { return XCTFail() }
        let truncate = try FileHandle(forWritingTo: file); try truncate.truncate(atOffset: 0); try truncate.close()
        let cp = AudioHubRawTranscriptReader.Checkpoint(offset: line.nextOffset, physicalLine: 1, snapshot: line.snapshot)
        XCTAssertThrowsError(try AudioHubRawTranscriptReader.read(sessionsRoot: r, sessionID: "ctx-test", checkpoint: cp,
            maxReadBytes: 100, maxLineBytes: 100)) { XCTAssertEqual($0 as? AudioHubRawTranscriptReader.Error, .truncatedCursor) }
        try Data("one\ntwo\n".utf8).write(to: file)
        let replacement = file.deletingLastPathComponent().appendingPathComponent("replacement")
        try Data("new\n".utf8).write(to: replacement); try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: replacement, to: file)
        XCTAssertThrowsError(try AudioHubRawTranscriptReader.read(sessionsRoot: r, sessionID: "ctx-test", checkpoint: cp,
            maxReadBytes: 100, maxLineBytes: 100)) { XCTAssertEqual($0 as? AudioHubRawTranscriptReader.Error, .staleCursor) }
    }

    func testSymlinkSessionIsRefused() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let outside = try root(); defer { try? FileManager.default.removeItem(at: outside) }
        _ = try rawURL(outside, "real")
        try FileManager.default.createSymbolicLink(atPath: r.appendingPathComponent("ctx-test").path,
                                                   withDestinationPath: outside.appendingPathComponent("real").path)
        XCTAssertThrowsError(try AudioHubRawTranscriptReader.read(sessionsRoot: r, sessionID: "ctx-test",
            checkpoint: .init(), maxReadBytes: 10, maxLineBytes: 10)) { XCTAssertEqual($0 as? AudioHubRawTranscriptReader.Error, .unsafePath) }
    }

    func testFIFOAndForgedUnterminatedEOFBoundaryAreRejected() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let file = try rawURL(r); try Data("tail".utf8).write(to: file)
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0)
        let snap = AudioHubRawTranscriptReader.Snapshot(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), length: 4)
        XCTAssertThrowsError(try AudioHubRawTranscriptReader.read(sessionsRoot: r, sessionID: "ctx-test",
            checkpoint: .init(offset: 4, physicalLine: 1, snapshot: snap), maxReadBytes: 10, maxLineBytes: 10)) {
            XCTAssertEqual($0 as? AudioHubRawTranscriptReader.Error, .staleCursor)
        }

        let fifoRoot = try root(); defer { try? FileManager.default.removeItem(at: fifoRoot) }
        let fifoRaw = try rawURL(fifoRoot)
        XCTAssertEqual(mkfifo(fifoRaw.path, 0o600), 0)
        XCTAssertThrowsError(try AudioHubRawTranscriptReader.read(sessionsRoot: fifoRoot, sessionID: "ctx-test",
            checkpoint: .init(), maxReadBytes: 10, maxLineBytes: 10)) {
            XCTAssertEqual($0 as? AudioHubRawTranscriptReader.Error, .unsafePath)
        }
    }
}
