import Foundation
import XCTest
@testable import ClawGate

final class AudioHubSourceRegistrationTests: XCTestCase {
    private let source = "00000000-0000-4000-8000-000000000001"

    private func row(_ id: String, fileName: String = "clip.m4a") -> MeetingAudioArchive.Chunk {
        MeetingAudioArchive.Chunk(id: id, source: "mic", startedAt: 1, endedAt: 2, fileName: fileName)
    }

    private func registration(id: String, bytes: Data, original: AudioHubOutbox.OriginalReference) throws -> AudioHubControlStore.SelectedRegistration {
        let item = row(id, fileName: URL(fileURLWithPath: original.sourceRelativePath).lastPathComponent)
        return .init(meetingID: "m1", indexData: try JSONEncoder().encode([item]),
                     assets: [.init(row: item, original: original)])
    }

    func testSelectedRegistrationReopensAndDuplicateIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controlURL = root.appendingPathComponent("control")
        let original = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m1/audio/clip.m4a",
                                                              sha256: String(repeating: "a", count: 64), byteLength: 1)
        let value = try registration(id: "row-1", bytes: Data("x".utf8), original: original)
        let control = try AudioHubControlStore(directory: controlURL, sourceUUID: source, maxControlBytes: 8_000)
        try control.registerSelected(value)
        try control.registerSelected(value)
        try control.recordSelectedGap(registration: value, reason: "source_original_missing")
        try control.recordSelectedGap(registration: value, reason: "source_original_changed") // first observation wins
        let reopened = try AudioHubControlStore(directory: controlURL, sourceUUID: source, maxControlBytes: 8_000)
        XCTAssertEqual(try reopened.selectedRegistrations(), [value])
        XCTAssertEqual(try reopened.selectedGapReasons().count, 1)
        XCTAssertEqual(try reopened.selectedGapReasons().values.first, "source_original_missing")
    }

    func testSelectedGapRequiresRegisteredIntent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m1/audio/clip.m4a",
                                                              sha256: String(repeating: "a", count: 64), byteLength: 1)
        let value = try registration(id: "row-1", bytes: Data("x".utf8), original: original)
        let control = try AudioHubControlStore(directory: root.appendingPathComponent("control"), sourceUUID: source, maxControlBytes: 8_000)
        XCTAssertThrowsError(try control.recordSelectedGap(registration: value, reason: "source_original_missing")) {
            XCTAssertEqual($0 as? AudioHubControlStore.Failure, .invalidState)
        }
        XCTAssertThrowsError(try control.recordSelectedGap(registration: value, reason: "other")) {
            XCTAssertEqual($0 as? AudioHubControlStore.Failure, .invalidState)
        }
    }

    func testCapacityFailurePreservesExistingRegistration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controlURL = root.appendingPathComponent("control")
        let original = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m1/audio/clip.m4a",
                                                              sha256: String(repeating: "a", count: 64), byteLength: 1)
        let first = try registration(id: "row-1", bytes: Data("x".utf8), original: original)
        let control = try AudioHubControlStore(directory: controlURL, sourceUUID: source, maxControlBytes: 1_200)
        try control.registerSelected(first)
        let huge = try registration(id: String(repeating: "r", count: 500), bytes: Data("x".utf8), original: original)
        XCTAssertThrowsError(try control.registerSelected(huge)) { XCTAssertEqual($0 as? AudioHubControlStore.Failure, .capacityExceeded) }
        XCTAssertEqual(try control.selectedRegistrations(), [first])
    }

    func testInspectReturnsActualSafeAssetReference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("meetings/m1/audio/clip.m4a")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("safe-audio".utf8)
        try bytes.write(to: audio)
        let reference = try AudioHubOriginalReader.inspect(root: root, relativePath: "meetings/m1/audio/clip.m4a")
        XCTAssertEqual(reference.sourceRelativePath, "meetings/m1/audio/clip.m4a")
        XCTAssertEqual(reference.byteLength, Int64(bytes.count))
        XCTAssertEqual(reference.sha256.count, 64)
    }
}
