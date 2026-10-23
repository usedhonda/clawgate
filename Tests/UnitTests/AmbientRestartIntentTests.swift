import XCTest
@testable import ClawGate

final class AmbientRestartIntentTests: XCTestCase {
    func testNewerPrivacyControlCannotBeSettledByOlderCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("intent.json")
        let store = AmbientRestartIntent(url: url)
        let start = try store.begin()
        let stop = try store.begin()
        var record = try JSONDecoder().decode(AmbientRestartIntent.Record.self, from: Data(contentsOf: url))
        XCTAssertFalse(record.settled)
        XCTAssertEqual(record.revision, stop)
        try store.settle(stop, captureState: "idle", streaming: false)
        try store.settle(start, captureState: "capturing", streaming: true)
        record = try JSONDecoder().decode(AmbientRestartIntent.Record.self, from: Data(contentsOf: url))
        XCTAssertEqual(record.revision, stop)
        XCTAssertTrue(record.settled)
        XCTAssertEqual(record.captureState, "idle")
        XCTAssertEqual(record.streaming, false)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testNewProcessDoesNotResetLastUserChoiceRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("intent.json")
        let first = AmbientRestartIntent(url: url)
        let revision = try first.begin()
        try first.settle(revision, captureState: "capturing", streaming: false)
        let before = try Data(contentsOf: url)
        let second = AmbientRestartIntent(url: url)
        try second.settle(nil, captureState: "idle", streaming: false)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}
