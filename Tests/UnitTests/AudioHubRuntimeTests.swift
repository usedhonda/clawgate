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

    func testSelectedMissingOrChangedAfterCommitPersistsNonACKGap() throws {
        for changed in [false, true] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var runtime = try fixture.open()
            let audio = fixture.root.appendingPathComponent("meetings/m/audio")
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
            let file = audio.appendingPathComponent("new.m4a")
            try Data("initial".utf8).write(to: file)
            let row = MeetingAudioArchive.Chunk(id: "new", source: "mic", startedAt: 2, endedAt: 3, fileName: "new.m4a")
            let index = try JSONEncoder().encode([row])
            try runtime.registerSelectedCommit(meetingID: "m", indexData: index)
            try index.write(to: audio.appendingPathComponent("index.json"), options: .atomic)
            if changed { try Data("changed".utf8).write(to: file) }
            else { try FileManager.default.removeItem(at: file) }
            XCTAssertThrowsError(try runtime.recover())
            XCTAssertEqual(try runtime.pendingCount(), 0)
            runtime = try fixture.open()
            XCTAssertEqual(Array(try runtime.registrationGapReasons().values),
                           [changed ? "source_original_changed" : "source_original_missing"])
            XCTAssertEqual(try runtime.pendingCount(), 0)
        }
    }

    func testSelectedRegistrationIsolatesUnreadRowsAndPreservesFirstBinding() throws {
        for kind in ["missing", "read", "unsafe"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var runtime = try fixture.open()
            let audio = fixture.root.appendingPathComponent("meetings/m/audio")
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
            let badFile = audio.appendingPathComponent("bad.m4a")
            if kind == "read" {
                try Data("unread".utf8).write(to: badFile)
                XCTAssertEqual(chmod(badFile.path, 0), 0)
            } else if kind == "unsafe" {
                try FileManager.default.createSymbolicLink(at: badFile,
                    withDestinationURL: fixture.root.appendingPathComponent("outside"))
            }
            defer { if kind == "read" { _ = chmod(badFile.path, 0o600) } }
            let bad = MeetingAudioArchive.Chunk(id: "bad", source: "mic", startedAt: 2, endedAt: 3, fileName: "bad.m4a")
            let good = MeetingAudioArchive.Chunk(id: "good", source: "mic", startedAt: 3, endedAt: 4, fileName: "good.m4a")
            try Data("healthy".utf8).write(to: audio.appendingPathComponent("good.m4a"))
            let index = try JSONEncoder().encode([bad, good])
            XCTAssertThrowsError(try runtime.registerSelectedCommit(meetingID: "m", indexData: index))
            XCTAssertEqual(runtime.lastFailure, "selected_registration_failed")
            let failures = try runtime.registrationFailures()
            XCTAssertEqual(failures.count, 1)
            XCTAssertNil(failures.first?.knownOriginal)
            XCTAssertEqual(failures.first?.reason, kind == "missing" ? "source_original_missing" :
                kind == "read" ? "source_original_read_failed" : "source_original_unsafe")
            XCTAssertEqual(try runtime.pendingCount(), 0)
            try index.write(to: audio.appendingPathComponent("index.json"))
            runtime = try fixture.open()
            XCTAssertEqual(try runtime.registrationFailures(), failures)
            try runtime.recover()
            let pending = try runtime.pendingRecords()
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(pending.first?.sourceRecordRef, "clawgate:meeting:m:audio:good")
            // A source-index-only update must not change first registration bytes/ID.
            XCTAssertThrowsError(try runtime.registerSelectedCommit(meetingID: "m",
                indexData: JSONEncoder().encode([good, bad])))
            runtime = try fixture.open()
            try runtime.recover()
            XCTAssertEqual(try runtime.pendingRecords(), pending)
            let state = try Data(contentsOf: fixture.root.appendingPathComponent("runtime/control/control.json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: state) as? [String: Any])
            let registrations = try XCTUnwrap(json["selectedRegistrations"] as? [String: Any])
            XCTAssertEqual(registrations.count, 1)
            let observations = try XCTUnwrap(json["selectedRegistrationFailures"] as? [String: Any])
            let observation = try XCTUnwrap(observations.values.first as? [String: Any])
            XCTAssertNil(observation["assets"])
            XCTAssertNil(observation["sha256"])
            XCTAssertNil(observation["byteLength"])
        }
    }

    func testPrunedBaselineIsDiagnosticOnlyAndHealthyRowStillRegisters() throws {
        for changed in [false, true] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var runtime = try fixture.open()
            let audio = fixture.root.appendingPathComponent("meetings/m/audio")
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
            let baseline = MeetingAudioArchive.Chunk(id: "old", source: "mic", startedAt: 1, endedAt: 2, fileName: "old.m4a")
            let good = MeetingAudioArchive.Chunk(id: "good", source: "mic", startedAt: 3, endedAt: 4, fileName: "good.m4a")
            try Data("healthy".utf8).write(to: audio.appendingPathComponent("good.m4a"))
            if changed { try Data("changed".utf8).write(to: audio.appendingPathComponent("old.m4a")) }
            let index = try JSONEncoder().encode([baseline, good])
            XCTAssertThrowsError(try runtime.registerSelectedCommit(meetingID: "m", indexData: index))
            let failure = try XCTUnwrap(runtime.registrationFailures().first)
            XCTAssertEqual(failure.knownOriginal?.sha256, Self.hash(Data("old".utf8)))
            XCTAssertEqual(failure.knownOriginal?.byteLength, 3)
            XCTAssertEqual(failure.reason, changed ? "source_original_changed" : "source_original_missing")
            try index.write(to: audio.appendingPathComponent("index.json"))
            runtime = try fixture.open()
            try runtime.recover()
            XCTAssertEqual(try runtime.pendingRecords().map(\.sourceRecordRef), ["clawgate:meeting:m:audio:good"])
        }
    }

    func testUnavailableFailureStoreNeverReturnsRegistrationSuccess() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtime = try fixture.open()
        let lock = fixture.root.appendingPathComponent("runtime/control/.control.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let missing = MeetingAudioArchive.Chunk(id: "missing", source: "mic", startedAt: 1, endedAt: 2, fileName: "missing.m4a")
        XCTAssertThrowsError(try runtime.registerSelectedCommit(meetingID: "m",
            indexData: JSONEncoder().encode([missing]))) {
            XCTAssertEqual($0 as? AudioHubControlStore.Failure, .storageFailed)
        }
        XCTAssertEqual(runtime.lastFailure, "selected_registration_failed")
        XCTAssertEqual(try runtime.pendingCount(), 0)
        XCTAssertThrowsError(try runtime.registrationFailures())
        let reopened = try fixture.open()
        XCTAssertTrue(try reopened.registrationFailures().isEmpty)
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
