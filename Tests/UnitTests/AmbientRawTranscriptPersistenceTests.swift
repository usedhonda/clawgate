import XCTest
import Darwin
@testable import ClawGate

final class AmbientRawTranscriptPersistenceTests: XCTestCase {
    func testRawAppendPreservesJSONLineAndReportsWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raw-append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let segment = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "a\n b")
        let url = root.appendingPathComponent("raw.jsonl")
        try AmbientRawTranscriptAppender.append([segment], to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.last, 0x0A)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: Data(data.dropLast()))
        XCTAssertEqual(decoded, segment)

        let prefix = data
        try AmbientRawTranscriptAppender.append([segment], to: url)
        let appended = try Data(contentsOf: url)
        XCTAssertEqual(Data(appended.prefix(prefix.count)), prefix)

        let directoryTarget = root.appendingPathComponent("not-a-file")
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AmbientRawTranscriptAppender.append([segment], to: directoryTarget)) {
            XCTAssertEqual($0 as? AmbientRawTranscriptPersistenceError, .writeFailed)
            XCTAssertEqual(String(describing: $0), "raw_transcript_persistence_failed")
        }

        let torn = root.appendingPathComponent("torn.jsonl")
        try Data("prefix-without-newline".utf8).write(to: torn)
        let before = try Data(contentsOf: torn)
        XCTAssertThrowsError(try AmbientRawTranscriptAppender.append([segment], to: torn)) {
            XCTAssertEqual($0 as? AmbientRawTranscriptPersistenceError, .incompleteTail)
        }
        XCTAssertEqual(try Data(contentsOf: torn), before)

        let target = root.appendingPathComponent("target.jsonl")
        try Data("target\n".utf8).write(to: target)
        let link = root.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try AmbientRawTranscriptAppender.append([segment], to: link))

        let fifo = root.appendingPathComponent("fifo.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try AmbientRawTranscriptAppender.append([segment], to: fifo))

    }
}
