import CryptoKit
import XCTest
@testable import ClawGate

final class AudioHubSelectedMeetingAdmissionTests: XCTestCase {
    func testReorderAndAppendReuseExistingAssetEnvelope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selected-\(UUID().uuidString)")
        let audio = root.appendingPathComponent("meetings/m1/audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let bytes = Data("asset-a".utf8); try bytes.write(to: audio.appendingPathComponent("a.wav"))
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let ref = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m1/audio/a.wav", sha256: sha, byteLength: Int64(bytes.count))
        let row = MeetingAudioArchive.Chunk(id: "row-a", source: "mic", startedAt: 100, endedAt: 101, fileName: "a.wav")
        let asset = AudioHubSelectedMeetingAdmission.Asset(row: row, original: ref)
        let outbox = try AudioHubOutbox(directory: root.appendingPathComponent("outbox"), maxMetadataBytes: 64 * 1024,
                                        sourceUUID: "11111111-1111-1111-1111-111111111111")
        let controlURL = root.appendingPathComponent("control")
        var control = try AudioHubControlStore(directory: controlURL, sourceUUID: outbox.sourceUUID, maxControlBytes: 64 * 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        let indexV1 = try JSONEncoder().encode([row])
        // Another valid journal writer advances disk before this admission:
        // queue commit succeeds, journal CAS then fails. Reopen must reuse bytes.
        let newer = try AudioHubControlStore(directory: controlURL, sourceUUID: outbox.sourceUUID, maxControlBytes: 64 * 1024)
        _ = try newer.excludeOriginal(sourceRecordRef: "clock-fixture", revision: "sha256:" + String(repeating: "0", count: 64))
        XCTAssertThrowsError(try AudioHubSelectedMeetingAdmission.admit(meetingID: "m1", indexData: indexV1, assets: [asset], selectedIDs: ["row-a"], originalsRoot: root, outbox: outbox, control: control))
        let body = try XCTUnwrap(outbox.pending(limit: 1).first?.envelope)
        XCTAssertEqual(try outbox.pending(limit: 1).first?.original, ref)
        control = try AudioHubControlStore(directory: controlURL, sourceUUID: outbox.sourceUUID, maxControlBytes: 64 * 1024)
        let indexV2 = try JSONEncoder().encode([MeetingAudioArchive.Chunk(id: "row-other", source: "mic", startedAt: 200, endedAt: 201, fileName: "other.wav"), row])
        _ = try AudioHubSelectedMeetingAdmission.admit(meetingID: "m1", indexData: indexV2, assets: [asset], selectedIDs: ["row-a"], originalsRoot: root, outbox: outbox, control: control)
        XCTAssertEqual(try outbox.pending(limit: 1).first?.envelope, body)
        let reopenedOutbox = try AudioHubOutbox(directory: root.appendingPathComponent("outbox"), maxMetadataBytes: 64 * 1024, sourceUUID: outbox.sourceUUID)
        let reopenedControl = try AudioHubControlStore(directory: controlURL, sourceUUID: outbox.sourceUUID, maxControlBytes: 64 * 1024)
        _ = try AudioHubSelectedMeetingAdmission.admit(meetingID: "m1", indexData: indexV2, assets: [asset], selectedIDs: ["row-a"], originalsRoot: root, outbox: reopenedOutbox, control: reopenedControl)
        XCTAssertEqual(try reopenedOutbox.pending(limit: 1).first?.envelope, body)
        let pending = try XCTUnwrap(reopenedOutbox.pending(limit: 1).first)
        try reopenedOutbox.acknowledge(externalID: pending.externalID, expectedEnvelope: pending.envelope, receipt: Data("ack".utf8))
        let afterAck = try AudioHubOutbox(directory: root.appendingPathComponent("outbox"), maxMetadataBytes: 64 * 1024, sourceUUID: outbox.sourceUUID)
        let afterControl = try AudioHubControlStore(directory: controlURL, sourceUUID: outbox.sourceUUID, maxControlBytes: 64 * 1024)
        _ = try AudioHubSelectedMeetingAdmission.admit(meetingID: "m1", indexData: indexV2, assets: [asset], selectedIDs: ["row-a"], originalsRoot: root, outbox: afterAck, control: afterControl)
        XCTAssertTrue(try afterAck.pending(limit: 1).isEmpty)
        let changedRow = MeetingAudioArchive.Chunk(id: "row-a", source: "mic", startedAt: 101, endedAt: 102, fileName: "a.wav")
        let changedIndex = try JSONEncoder().encode([changedRow])
        let changedAsset = AudioHubSelectedMeetingAdmission.Asset(row: changedRow, original: ref)
        _ = try AudioHubSelectedMeetingAdmission.admit(meetingID: "m1", indexData: changedIndex, assets: [changedAsset], selectedIDs: ["row-a"], originalsRoot: root, outbox: afterAck, control: afterControl)
        XCTAssertEqual(try afterAck.pending(limit: 1).count, 1)
        XCTAssertNotEqual(try afterAck.pending(limit: 1).first?.externalID, pending.externalID)
    }

    func testIndexRowMismatchIsRejectedBeforeAdmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selected-mismatch-\(UUID().uuidString)")
        let audio = root.appendingPathComponent("meetings/m1/audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let bytes = Data("asset".utf8); try bytes.write(to: audio.appendingPathComponent("a.wav"))
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let original = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m1/audio/a.wav", sha256: sha, byteLength: Int64(bytes.count))
        let selected = MeetingAudioArchive.Chunk(id: "row-a", source: "mic", startedAt: 1, endedAt: 2, fileName: "a.wav")
        let indexed = MeetingAudioArchive.Chunk(id: "row-a", source: "system", startedAt: 1, endedAt: 2, fileName: "a.wav")
        let outbox = try AudioHubOutbox(directory: root.appendingPathComponent("outbox"), maxMetadataBytes: 64 * 1024, sourceUUID: "11111111-1111-1111-1111-111111111111")
        let control = try AudioHubControlStore(directory: root.appendingPathComponent("control"), sourceUUID: outbox.sourceUUID, maxControlBytes: 64 * 1024)
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyReference = try AudioHubOutbox.OriginalReference(sourceRelativePath: original.sourceRelativePath, sha256: original.sha256, byteLength: 0)
        XCTAssertThrowsError(try AudioHubSelectedMeetingAdmission.admit(meetingID: "m1", indexData: try JSONEncoder().encode([selected]), assets: [.init(row: selected, original: emptyReference)], selectedIDs: ["row-a"], originalsRoot: root, outbox: outbox, control: control)) {
            XCTAssertEqual($0 as? AudioHubSelectedMeetingAdmission.Error, .invalidSelection)
        }
        XCTAssertThrowsError(try AudioHubSelectedMeetingAdmission.admit(meetingID: "m1", indexData: try JSONEncoder().encode([indexed]), assets: [.init(row: selected, original: original)], selectedIDs: ["row-a"], originalsRoot: root, outbox: outbox, control: control)) {
            XCTAssertEqual($0 as? AudioHubSelectedMeetingAdmission.Error, .invalidIndex)
        }
    }
}
