#if DEBUG
import XCTest
@testable import ClawGate

final class NativeInputFixturePersistenceTests: XCTestCase {
    func testDisconnectedFixtureCannotOverwriteExistingLogButNormalModelPersists() throws {
        var original = ""
        let root = NSTemporaryDirectory() + "native-fixture-\(UUID().uuidString)"
        let isolation = PetLogTestIsolation.acquire(overriding: {
            original = PetLogStore.dir
            PetLogStore.dir = root
        }, restoring: {
            try? FileManager.default.removeItem(atPath: root)
            PetLogStore.dir = original
        })
        defer { isolation.release() }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: root).appendingPathComponent("log.json")
        let sentinel = Data("[]".utf8)
        try sentinel.write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let envelope = PetLogQueryEnvelope(
            requestId: "fixture-request", actionId: "slot-0", instruction: "synthetic",
            queryTimestamp: Date(), anchorTimestamp: Date(), scopeOverride: nil,
            coverageStart: nil, coverageEnd: nil, completeBeforeAnchor: true,
            segments: [PetLogRawSegment(id: "fixture-segment", capturedAt: nil,
                                       startSeconds: 0, endSeconds: 1, speaker: nil, text: "synthetic")])
        let fixture = PetModel()
        fixture.persistenceDisabledForFixture = true
        XCTAssertFalse(fixture.sendLogInstruction(envelope: envelope))
        XCTAssertFalse(fixture.logReplies.isEmpty, "Exercise the actual refusal append, not an earlier guard")
        XCTAssertEqual(try Data(contentsOf: file), sentinel)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), ["log.json"])

        let normal = PetModel()
        XCTAssertFalse(normal.sendLogInstruction(envelope: envelope))
        XCTAssertNotEqual(try Data(contentsOf: file), sentinel, "The instance seam must not disable normal persistence")
    }
}
#endif
