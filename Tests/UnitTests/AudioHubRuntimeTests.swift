import XCTest
import Darwin
import CryptoKit
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
        let value: [String: Any] = ["version": 2, "maxMetadataBytes": 1,
                                    "maxControlBytes": 1, "sessions": [], "committedOriginals": []]
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
        let manifest = AudioHubActivationManifest(version: 2,
            maxMetadataBytes: AudioHubActivationManifest.approvedMetadataBytes,
            maxControlBytes: AudioHubActivationManifest.approvedControlBytes,
            sessions: [.init(sessionID: "listed", initial: .init(offset: 0, physicalLine: 0,
                snapshot: .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), length: UInt64(info.st_size))),
                prefixSHA256: Self.hash(Data()))],
            committedOriginals: [])
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

    func testFutureRawWriterRegistersBeforeBytesAndRecoversAfterRestart() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var runtime = try fixture.open()
        let raw = fixture.root.appendingPathComponent("sessions/future/transcripts/raw.jsonl")
        try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
        var segment = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "fixture")
        segment.capturedAt = 1_700_000_000
        var registrationError: Error?
        try AmbientRawTranscriptAppender.append([segment], to: raw) { snapshot in
            XCTAssertEqual(snapshot.length, 0)
            do { try runtime.registerRawWriter(sessionID: "future", snapshot: snapshot) }
            catch { registrationError = error }
        }
        XCTAssertNil(registrationError)
        runtime = try fixture.open()
        try runtime.recover()
        _ = try runtime.scanAvailable()
        XCTAssertEqual(try runtime.pendingCount(), 1)
        let unlisted = fixture.root.appendingPathComponent("sessions/past/transcripts/raw.jsonl")
        try FileManager.default.createDirectory(at: unlisted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: unlisted)
        var oldRejected = false
        try AmbientRawTranscriptAppender.append([segment], to: unlisted) { snapshot in
            do { try runtime.registerRawWriter(sessionID: "past", snapshot: snapshot) }
            catch { oldRejected = true }
        }
        XCTAssertTrue(oldRejected)
        XCTAssertEqual(runtime.lastFailure, "raw_registration_failed")
        XCTAssertGreaterThan(try Data(contentsOf: unlisted).count, 4)
        XCTAssertEqual(try runtime.pendingCount(), 1)
    }

    func testBaselinePrefixMismatchRejectsScannerWithoutAdmittingHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let raw = fixture.root.appendingPathComponent("sessions/listed/transcripts/raw.jsonl")
        try Data("changed\n".utf8).write(to: raw)
        let runtime = try fixture.open()
        XCTAssertThrowsError(try runtime.recover())
        XCTAssertEqual(try runtime.pendingCount(), 0)
    }

    func testSelectedCoverageIsNotReuploadedAndPrecommitIntentRecovers() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var runtime = try fixture.open()
        try runtime.recover()
        XCTAssertEqual(try runtime.pendingCount(), 0)
        let audio = fixture.root.appendingPathComponent("meetings/m/audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let originalBytes = Data("old".utf8)
        try originalBytes.write(to: audio.appendingPathComponent("old.m4a"))
        let old = MeetingAudioArchive.Chunk(id: "old", source: "mic", startedAt: 1, endedAt: 2, fileName: "old.m4a")
        try runtime.registerSelectedCommit(meetingID: "m", indexData: JSONEncoder().encode([old]))
        XCTAssertEqual(try runtime.pendingCount(), 0)
        let row = MeetingAudioArchive.Chunk(id: "new", source: "mic", startedAt: 2, endedAt: 3, fileName: "new.m4a")
        try Data("new".utf8).write(to: audio.appendingPathComponent("new.m4a"))
        let index = try JSONEncoder().encode([old, row])
        try runtime.registerSelectedCommit(meetingID: "m", indexData: index)
        runtime = try fixture.open()
        XCTAssertThrowsError(try runtime.recover()) // index has not committed
        XCTAssertEqual(try runtime.pendingCount(), 0)
        try index.write(to: audio.appendingPathComponent("index.json"), options: .atomic)
        try runtime.recover()
        let pending = try runtime.pendingRecords()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.sourceRecordRef, "clawgate:meeting:m:audio:new")
        runtime = try fixture.open()
        try runtime.recover()
        XCTAssertEqual(try runtime.pendingRecords(), pending)
        // Already admitted work remains recoverable even after source index changes.
        try FileManager.default.removeItem(at: audio.appendingPathComponent("index.json"))
        let other = fixture.root.appendingPathComponent("outside.json")
        try index.write(to: other)
        try FileManager.default.createSymbolicLink(at: audio.appendingPathComponent("index.json"), withDestinationURL: other)
        try runtime.recover()
        XCTAssertEqual(try runtime.pendingRecords(), pending)
    }

    private struct Fixture {
        let root: URL
        func open() throws -> AudioHubRuntime {
            try XCTUnwrap(AudioHubRuntime(manifestURL: root.appendingPathComponent("activation.json"),
                sessionsRoot: root.appendingPathComponent("sessions"), meetingsRoot: root,
                runtimeRoot: root.appendingPathComponent("runtime"), provisionLoader: { nil }))
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let raw = root.appendingPathComponent("sessions/listed/transcripts/raw.jsonl")
        try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
        let prefix = Data("{\"text\":\"old\",\"capturedAt\":1700000000}\n".utf8)
        try prefix.write(to: raw)
        var info = stat(); XCTAssertEqual(lstat(raw.path, &info), 0)
        let value = AudioHubActivationManifest(version: 2,
            maxMetadataBytes: AudioHubActivationManifest.approvedMetadataBytes,
            maxControlBytes: AudioHubActivationManifest.approvedControlBytes,
            sessions: [.init(sessionID: "listed", initial: .init(offset: UInt64(prefix.count), physicalLine: 1,
                snapshot: .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), length: UInt64(prefix.count))),
                prefixSHA256: Self.hash(prefix))],
            committedOriginals: [.init(meetingID: "m", chunkID: "old", sha256: Self.hash(Data("old".utf8)),
                byteLength: 3, sourceChunk: .init(id: "old", source: "mic", startedAt: 1, endedAt: 2))])
        let file = root.appendingPathComponent("activation.json")
        try JSONEncoder().encode(value).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return .init(root: root)
    }

    private static func hash(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
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
