import XCTest
@testable import ClawGate

final class MeetingMinutesPublisherIdentityTests: XCTestCase {
    func testCandidateUsesExistingPublicIdentityWithoutEnrollmentOrCreatingMissingIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        XCTAssertNil(try MeetingMinutesPublisherIdentity.prepare(store: store,
            existingDeviceID: nil, maxMetadataBytes: 128 * 1024))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let deviceID = String(repeating: "0", count: 64)
        let file = try XCTUnwrap(MeetingMinutesPublisherIdentity.prepare(store: store,
            existingDeviceID: deviceID, maxMetadataBytes: 128 * 1024))
        let candidate = try JSONDecoder().decode(MeetingMinutesPublisherIdentity.self, from: Data(contentsOf: file))
        XCTAssertEqual(candidate.deviceId, deviceID)
        XCTAssertEqual(candidate.evidence, "existing_connected_ws_device_identity")
        XCTAssertNotNil(UUID(uuidString: candidate.sourceUUID))
        let queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        XCTAssertEqual(queue.sourceUUID, candidate.sourceUUID)
        XCTAssertTrue(try queue.publications().isEmpty) // no historical enrollment or send
        _ = try MeetingMinutesPublisherIdentity.prepare(store: store, existingDeviceID: deviceID,
            maxMetadataBytes: 128 * 1024)
        XCTAssertEqual(try JSONDecoder().decode(MeetingMinutesPublisherIdentity.self,
            from: Data(contentsOf: file)), candidate)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "sourceUUID", "deviceId", "evidence"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
