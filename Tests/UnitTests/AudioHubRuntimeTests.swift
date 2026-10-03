import XCTest
import Darwin
@testable import ClawGate

final class AudioHubRuntimeTests: XCTestCase {
    func testAbsentManifestLeavesRouteUnconfigured() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try AudioHubRuntime(
            manifestURL: root.appendingPathComponent("activation.json"),
            sessionsRoot: root, meetingsRoot: root, runtimeRoot: root.appendingPathComponent("runtime")))
    }

    func testManifestMustUseApprovedGlobalBudgets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let value: [String: Any] = ["version": 1, "maxMetadataBytes": 1,
                                    "maxControlBytes": 1, "sessions": [], "selectedMeetings": []]
        let url = root.appendingPathComponent("activation.json")
        try JSONSerialization.data(withJSONObject: value).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertThrowsError(try AudioHubRuntime(manifestURL: url, sessionsRoot: root,
                                                 meetingsRoot: root, runtimeRoot: root.appendingPathComponent("runtime")))
    }
    func testListedTwoLineBacklogAndStrictReceiptRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let raw = sessions.appendingPathComponent("listed/transcripts/raw.jsonl")
        try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data("{\"text\":\"fixture\",\"capturedAt\":1700000000}\n".utf8)
        try (line + line).write(to: raw)
        let other = sessions.appendingPathComponent("unlisted/transcripts/raw.jsonl")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try line.write(to: other)
        var info = stat(); XCTAssertEqual(lstat(raw.path, &info), 0)
        let manifest = AudioHubActivationManifest(version: 1,
            maxMetadataBytes: AudioHubActivationManifest.approvedMetadataBytes,
            maxControlBytes: AudioHubActivationManifest.approvedControlBytes,
            sessions: [.init(sessionID: "listed", initial: .init(offset: 0, physicalLine: 0,
                snapshot: .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), length: UInt64(info.st_size))))],
            selectedMeetings: [])
        let file = root.appendingPathComponent("activation.json")
        try JSONEncoder().encode(manifest).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        func openRuntime() throws -> AudioHubRuntime {
            try XCTUnwrap(AudioHubRuntime(manifestURL: file, sessionsRoot: sessions,
                meetingsRoot: root, runtimeRoot: root.appendingPathComponent("runtime"), provisionLoader: { nil }))
        }
        var runtime = try openRuntime()
        try runtime.recover()
        XCTAssertFalse(try runtime.scanAvailable())
        let pending = try runtime.pendingRecords()
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { $0.sourceRecordRef.hasPrefix("clawgate:session:listed:") })
        do {
            _ = try await runtime.drain(metadataSender: { _ in try Self.receipt("wrong") })
            XCTFail("unmatched receipt must retain pending")
        } catch { }
        XCTAssertEqual(try runtime.pendingRecords(), pending)
        runtime = try openRuntime()
        try runtime.recover()
        XCTAssertFalse(try runtime.scanAvailable())
        XCTAssertEqual(try runtime.pendingRecords(), pending)
        let remains = try await runtime.drain(metadataSender: { try Self.receipt($0.externalID) })
        XCTAssertFalse(remains)
        XCTAssertEqual(try runtime.pendingCount(), 0)
        XCTAssertEqual(try Data(contentsOf: other), line)
    }

    func testSelectedIndexSymlinkIsRejectedBeforeAdmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("meetings/m/audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        try Data("[]".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: audio.appendingPathComponent("index.json"), withDestinationURL: outside)
        let original = try AudioHubOutbox.OriginalReference(sourceRelativePath: "meetings/m/audio/a.m4a",
            sha256: String(repeating: "a", count: 64), byteLength: 1)
        let manifest = AudioHubActivationManifest(version: 1,
            maxMetadataBytes: AudioHubActivationManifest.approvedMetadataBytes,
            maxControlBytes: AudioHubActivationManifest.approvedControlBytes, sessions: [],
            selectedMeetings: [.init(meetingID: "m", indexRelativePath: "meetings/m/audio/index.json",
                assets: [.init(row: .init(id: "chunk", source: "mic", startedAt: 1, endedAt: 2, fileName: "a.m4a"), original: original)])])
        let file = root.appendingPathComponent("activation.json")
        try JSONEncoder().encode(manifest).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let runtime = try XCTUnwrap(AudioHubRuntime(manifestURL: file, sessionsRoot: root,
            meetingsRoot: root, runtimeRoot: root.appendingPathComponent("runtime"), provisionLoader: { nil }))
        XCTAssertThrowsError(try runtime.recover()) { XCTAssertEqual($0 as? AudioHubRuntime.Failure, .invalidPath) }
        XCTAssertEqual(try runtime.pendingCount(), 0)
    }

    private static func receipt(_ externalID: String) throws -> HubAudioAdmission.Acknowledgement {
        let storage: [String: Any] = ["receipt_version": 1, "source": "clawgate", "external_id": externalID,
            "event_id": "22222222-2222-2222-2222-222222222222", "sha256": NSNull(),
            "byte_length": 0, "ingest_sequence": 1]
        let response = try JSONSerialization.data(withJSONObject: ["storage_receipt": storage])
        return try HubAudioAdmission.validate(response: response, externalID: externalID,
                                              sha256: nil, byteLength: 0, pipeline: nil)
    }

}
