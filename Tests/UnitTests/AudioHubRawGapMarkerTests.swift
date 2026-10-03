import XCTest
@testable import ClawGate

/// A failed first registration must leave a durable gap, not only a log line.
final class AudioHubRawGapMarkerTests: XCTestCase {
    func testFirstFailureIsPersistedAndKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("raw-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(AudioHubRawGapMarker.record(sessionDirectory: dir, sessionID: "ctx-a", reason: "runtime_unavailable"))
        XCTAssertTrue(AudioHubRawGapMarker.record(sessionDirectory: dir, sessionID: "ctx-a", reason: "registration_unconfigured"))
        let marker = try XCTUnwrap(AudioHubRawGapMarker.load(sessionDirectory: dir))
        XCTAssertEqual(marker.sessionID, "ctx-a")
        XCTAssertEqual(marker.reason, "runtime_unavailable")
    }
}
