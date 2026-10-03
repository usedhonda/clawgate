import CryptoKit
import Darwin
import XCTest
@testable import ClawGate

final class AudioHubOriginalReaderTests: XCTestCase {
    private func setup(_ bytes: Data) throws -> (URL, URL, AudioHubOutbox.OriginalReference) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("original-\(UUID().uuidString)")
        let file = root.appendingPathComponent("meetings/m1/audio/source.bin")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let reference = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m1/audio/source.bin",
                                                               sha256: digest, byteLength: Int64(bytes.count))
        return (root, file, reference)
    }

    func testExactBoundedChunks() throws {
        let bytes = Data("0123456789".utf8)
        let (root, _, reference) = try setup(bytes); defer { try? FileManager.default.removeItem(at: root) }
        let reader = try AudioHubOriginalReader(root: root, reference: reference)
        XCTAssertEqual(try reader.readChunk(offset: 0, limit: 4), Data("0123".utf8))
        XCTAssertEqual(try reader.readChunk(offset: 4, limit: 4), Data("4567".utf8))
        XCTAssertEqual(try reader.readChunk(offset: 8, limit: 4), Data("89".utf8))
        XCTAssertEqual(try reader.readChunk(offset: 10, limit: 4), Data())
        XCTAssertThrowsError(try reader.readChunk(offset: -1, limit: 4)) {
            XCTAssertEqual($0 as? AudioHubOriginalReader.Error, .invalidRange)
        }
        XCTAssertThrowsError(try reader.readChunk(offset: 0, limit: 0)) {
            XCTAssertEqual($0 as? AudioHubOriginalReader.Error, .invalidRange)
        }
        XCTAssertThrowsError(try reader.readChunk(offset: 0, limit: 4 * 1024 * 1024 + 1)) {
            XCTAssertEqual($0 as? AudioHubOriginalReader.Error, .invalidRange)
        }
    }

    func testHashAndLengthMismatch() throws {
        let (root, file, reference) = try setup(Data("source".utf8)); defer { try? FileManager.default.removeItem(at: root) }
        try Data("sourcx".utf8).write(to: file)
        XCTAssertThrowsError(try AudioHubOriginalReader(root: root, reference: reference)) {
            XCTAssertEqual($0 as? AudioHubOriginalReader.Error, .contentMismatch)
        }
    }

    func testSymlinkAndFIFORefused() throws {
        let (root, file, reference) = try setup(Data("source".utf8)); defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("meetings/m1/audio/link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let linkReference = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m1/audio/link.bin",
                                                                  sha256: reference.sha256, byteLength: reference.byteLength)
        XCTAssertThrowsError(try AudioHubOriginalReader(root: root, reference: linkReference)) {
            XCTAssertEqual($0 as? AudioHubOriginalReader.Error, .unsafePath)
        }
        let fifo = root.appendingPathComponent("meetings/m1/audio/fifo.bin")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let fifoReference = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m1/audio/fifo.bin",
                                                                  sha256: reference.sha256, byteLength: reference.byteLength)
        XCTAssertThrowsError(try AudioHubOriginalReader(root: root, reference: fifoReference)) {
            XCTAssertEqual($0 as? AudioHubOriginalReader.Error, .unsafePath)
        }
    }

    func testDeletionReplacementAndMutationAreRejected() throws {
        let (root, file, reference) = try setup(Data("source".utf8)); defer { try? FileManager.default.removeItem(at: root) }
        let reader = try AudioHubOriginalReader(root: root, reference: reference)
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try reader.readChunk(offset: 0, limit: 2)) {
            XCTAssertEqual($0 as? AudioHubOriginalReader.Error, .missingOriginal)
        }

        let (root2, file2, reference2) = try setup(Data("source".utf8)); defer { try? FileManager.default.removeItem(at: root2) }
        let reader2 = try AudioHubOriginalReader(root: root2, reference: reference2)
        try Data("changed".utf8).write(to: file2)
        XCTAssertThrowsError(try reader2.readChunk(offset: 0, limit: 2)) {
            XCTAssertEqual($0 as? AudioHubOriginalReader.Error, .sourceChanged)
        }

        let (root3, file3, reference3) = try setup(Data("source".utf8)); defer { try? FileManager.default.removeItem(at: root3) }
        let reader3 = try AudioHubOriginalReader(root: root3, reference: reference3)
        let replacement = file3.deletingLastPathComponent().appendingPathComponent("replacement.bin")
        try Data("source".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: file3)
        try FileManager.default.moveItem(at: replacement, to: file3)
        XCTAssertThrowsError(try reader3.readChunk(offset: 0, limit: 2)) {
            XCTAssertEqual($0 as? AudioHubOriginalReader.Error, .sourceChanged)
        }
    }
}
