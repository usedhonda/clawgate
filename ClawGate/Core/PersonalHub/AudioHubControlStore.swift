import Foundation
import Darwin
import CryptoKit

/// Inactive source-admission journal and explicit scanner checkpoint.
/// Not a delivery ACK. Staged source bytes consume this same control budget.
/// A caller must supply a separately agreed control budget before using it.
final class AudioHubControlStore {
    struct Checkpoint: Codable, Equatable {
        let sourceRecordRef: String
        let revisionRef: String
        let disposition: String
        let externalID: String?
        let reason: String?
        let coverage: String?
    }

    enum Failure: Error, Equatable {
        case invalidBudget, invalidState, capacityExceeded, storageFailed, wrongSource, staleWriter
    }

    struct Scan: Codable, Equatable {
        let initial: AudioHubRawTranscriptReader.Checkpoint
        var cursor: AudioHubRawTranscriptReader.Checkpoint
        var staged: AudioHubRawTranscriptReader.ReadResult?
    }

    struct Upload: Codable, Equatable {
        let sourceRecordRef: String
        let revision: String
        let bodySHA256: String
        let original: AudioHubOutbox.OriginalReference
        let pipeline: String
        var uploadID: String?
        var offset: Int64
        var finalized: Bool
        var binding: HubAudioAdmission.Binding?
        var gapReason: String?
        var gapCoverage: String?
    }

    private struct State: Codable {
        let version: Int
        let sourceUUID: String
        var checkpoints: [Checkpoint]
        var scans: [String: Scan]?
        var uploads: [String: Upload]?
    }

    private let stateURL: URL
    private let maxControlBytes: Int
    private let lock = NSLock()
    private var state: State
    private var storageFailed = false
    private var persistedHash: String?

    init(directory: URL, sourceUUID: String, maxControlBytes: Int) throws {
        guard maxControlBytes > 0, maxControlBytes < Int.max else { throw Failure.invalidBudget }
        guard UUID(uuidString: sourceUUID)?.uuidString.lowercased() == sourceUUID else { throw Failure.wrongSource }
        self.maxControlBytes = maxControlBytes
        stateURL = directory.appendingPathComponent("control.json")
        state = State(version: 1, sourceUUID: sourceUUID, checkpoints: [])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else { throw Failure.invalidState }
        let descriptor = open(stateURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor >= 0 {
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
                  info.st_size <= maxControlBytes else { throw Failure.invalidState }
            let data = try file.read(upToCount: maxControlBytes + 1) ?? Data()
            guard data.count <= maxControlBytes,
                  let loaded = try? JSONDecoder().decode(State.self, from: data), loaded.version == 1,
                  loaded.sourceUUID == sourceUUID, Self.valid(loaded) else { throw Failure.invalidState }
            state = loaded
            persistedHash = Self.hash(data)
        } else {
            guard errno == ENOENT else { throw Failure.invalidState }
            try persist(try encode(state))
        }
    }

    /// No default start position or implicit backfill. Reopen must name the
    /// identical initial boundary; the persisted cursor takes precedence.
    func startScan(sessionID: String, initial: AudioHubRawTranscriptReader.Checkpoint) throws {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Failure.storageFailed }
        guard Self.validCursor(initial), Self.validSession(sessionID) else { throw Failure.invalidState }
        if let existing = state.scans?[sessionID] {
            guard existing.initial == initial else { throw Failure.invalidState }
            return
        }
        var candidate = state
        var scans = candidate.scans ?? [:]
        scans[sessionID] = Scan(initial: initial, cursor: initial, staged: nil)
        candidate.scans = scans
        try replace(candidate)
    }

    func scan(sessionID: String) throws -> Scan {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Failure.storageFailed }
        guard let scan = state.scans?[sessionID] else { throw Failure.invalidState }
        return scan
    }

    /// Freeze the exact first-read bytes before queue/journal admission.
    func stage(sessionID: String, expected: AudioHubRawTranscriptReader.Checkpoint,
               line: AudioHubRawTranscriptReader.ReadResult) throws {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Failure.storageFailed }
        guard var scan = state.scans?[sessionID], scan.cursor == expected else { throw Failure.invalidState }
        if let existing = scan.staged {
            guard existing == line else { throw Failure.invalidState }
            return
        }
        scan.staged = line
        guard Self.validScan(scan) else { throw Failure.invalidState }
        var candidate = state; candidate.scans?[sessionID] = scan
        try replace(candidate)
    }

    /// Admission may already have committed before a crash. A saved journal
    /// entry, including an excluded clock gap, is mandatory before advancing.
    func advance(sessionID: String, expectedLine: AudioHubRawTranscriptReader.ReadResult,
                 checkpoint: Checkpoint) throws {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Failure.storageFailed }
        guard var scan = state.scans?[sessionID], scan.staged == expectedLine,
              state.checkpoints.contains(checkpoint) else { throw Failure.invalidState }
        let prepared = try AudioHubTranscriptWire.prepare(raw: expectedLine.rawLine,
            sourceSessionID: sessionID, line: Int(expectedLine.physicalLine))
        guard checkpoint.sourceRecordRef == prepared.sourceRecordRef,
              checkpoint.revisionRef == prepared.revisionRef else { throw Failure.invalidState }
        scan.cursor = .init(offset: expectedLine.nextOffset, physicalLine: expectedLine.nextPhysicalLine,
                            snapshot: expectedLine.snapshot)
        scan.staged = nil
        var candidate = state; candidate.scans?[sessionID] = scan
        try replace(candidate)
    }

    private func replace(_ candidate: State) throws {
        let data = try encode(candidate)
        do { try persist(data) } catch { storageFailed = true; throw error }
        state = candidate
    }

    /// This is upload progress, not event delivery. The caller's control cap
    /// includes these records; no separate or unbounded progress file exists.
    func startUpload(record: AudioHubOutbox.PendingRecord, pipeline: String) throws -> Upload {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Failure.storageFailed }
        guard let original = record.original, original.byteLength > 0, !pipeline.isEmpty,
              Self.hash(record.envelope) == record.bodySHA256,
              AudioHubOutbox.externalID(sourceUUID: state.sourceUUID, sourceRecordRef: record.sourceRecordRef,
                                       revision: record.revision) == record.externalID else { throw Failure.invalidState }
        if let old = state.uploads?[record.externalID] {
            guard old.sourceRecordRef == record.sourceRecordRef, old.revision == record.revision,
                  old.bodySHA256 == record.bodySHA256, old.original == original,
                  old.pipeline == pipeline else { throw Failure.invalidState }
            return old
        }
        let upload = Upload(sourceRecordRef: record.sourceRecordRef, revision: record.revision,
            bodySHA256: record.bodySHA256, original: original, pipeline: pipeline,
            uploadID: nil, offset: 0, finalized: false, binding: nil, gapReason: nil)
        var candidate = state; var uploads = candidate.uploads ?? [:]
        uploads[record.externalID] = upload; candidate.uploads = uploads
        guard Self.valid(candidate) else { throw Failure.invalidState }
        try replace(candidate)
        return upload
    }

    func updateUpload(externalID: String, expected: Upload, uploadID: String? = nil,
                      offset: Int64? = nil, finalized: Bool = false,
                      binding: HubAudioAdmission.Binding? = nil, missing: Bool = false,
                      changed: Bool = false) throws -> Upload {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Failure.storageFailed }
        guard var upload = state.uploads?[externalID], upload == expected else { throw Failure.invalidState }
        if let uploadID {
            guard upload.uploadID == nil || upload.uploadID == uploadID else { throw Failure.invalidState }
            upload.uploadID = uploadID
        }
        if let offset {
            guard offset >= upload.offset, offset <= upload.original.byteLength else { throw Failure.invalidState }
            upload.offset = offset
        }
        if finalized { upload.finalized = true }
        if let binding {
            guard upload.finalized, upload.binding == nil || upload.binding == binding else { throw Failure.invalidState }
            upload.binding = binding
        }
        if missing { upload.gapReason = "source_original_missing"; upload.gapCoverage = "excluded" }
        if changed { upload.gapReason = "source_original_changed"; upload.gapCoverage = "excluded" }
        var candidate = state; candidate.uploads?[externalID] = upload
        guard Self.valid(candidate) else { throw Failure.invalidState }
        try replace(candidate)
        return upload
    }

    func checkpoints() throws -> [Checkpoint] {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Failure.storageFailed }
        return state.checkpoints
    }

    /// Admit an immutable selected-original envelope after queue persistence.
    /// Replay reuses an existing pending record (queue-before-journal crash) or
    /// the existing journal checkpoint without rebuilding bytes.
    @discardableResult
    func admitOriginal(sourceRecordRef: String, revision: String, original: AudioHubOutbox.OriginalReference,
                       into outbox: AudioHubOutbox,
                       make: (String, String) throws -> Data) throws -> Checkpoint {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed, !sourceRecordRef.isEmpty, !revision.isEmpty,
              outbox.sourceUUID == state.sourceUUID else { throw Failure.invalidState }
        if let existing = state.checkpoints.first(where: { $0.sourceRecordRef == sourceRecordRef && $0.revisionRef == revision }) {
            return existing
        }
        let externalID = AudioHubOutbox.externalID(sourceUUID: state.sourceUUID,
                                                   sourceRecordRef: sourceRecordRef, revision: revision)
        let existing = try outbox.pending(limit: Int.max).first(where: { $0.externalID == externalID })
        if let existing {
            guard existing.sourceRecordRef == sourceRecordRef, existing.revision == revision,
                  existing.original == original else { throw Failure.invalidState }
        }
        let checkpoint = Checkpoint(sourceRecordRef: sourceRecordRef, revisionRef: revision,
                                    disposition: "enqueued", externalID: externalID, reason: nil, coverage: nil)
        var candidate = state; candidate.checkpoints.append(checkpoint)
        guard Self.valid(candidate) else { throw Failure.invalidState }
        let encoded = try encode(candidate)
        if existing == nil {
            _ = try outbox.enqueue(sourceRecordRef: sourceRecordRef, revision: revision, original: original, make: make)
        }
        do { try persist(encoded) } catch { storageFailed = true; throw error }
        state = candidate
        return checkpoint
    }

    @discardableResult
    func excludeOriginal(sourceRecordRef: String, revision: String) throws -> Checkpoint {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed, !sourceRecordRef.isEmpty, !revision.isEmpty else { throw Failure.invalidState }
        if let existing = state.checkpoints.first(where: { $0.sourceRecordRef == sourceRecordRef && $0.revisionRef == revision }) { return existing }
        let checkpoint = Checkpoint(sourceRecordRef: sourceRecordRef, revisionRef: revision,
                                    disposition: "excluded", externalID: nil,
                                    reason: "source_clock_unknown", coverage: "excluded")
        var candidate = state; candidate.checkpoints.append(checkpoint)
        guard Self.valid(candidate) else { throw Failure.invalidState }
        do { try persist(try encode(candidate)) } catch { storageFailed = true; throw error }
        state = candidate
        return checkpoint
    }

    /// Persist a clock gap, or enqueue immutable bytes before recording admission.
    /// Replay after queue-commit/journal-failure uses the same source/revision ID.
    /// No scan offset is advanced and no item is marked delivered by this helper.
    @discardableResult
    func admit(_ prepared: AudioHubTranscriptWire.PreparedRecord, into outbox: AudioHubOutbox) throws -> Checkpoint {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Failure.storageFailed }
        guard outbox.sourceUUID == state.sourceUUID else { throw Failure.wrongSource }
        if let existing = state.checkpoints.first(where: {
            $0.sourceRecordRef == prepared.sourceRecordRef && $0.revisionRef == prepared.revisionRef
        }) { return existing }

        let externalID = AudioHubOutbox.externalID(sourceUUID: state.sourceUUID,
                                                   sourceRecordRef: prepared.sourceRecordRef, revision: prepared.revisionRef)
        let checkpoint = Checkpoint(sourceRecordRef: prepared.sourceRecordRef, revisionRef: prepared.revisionRef,
                                    disposition: prepared.isGap ? "excluded" : "enqueued",
                                    externalID: prepared.isGap ? nil : externalID,
                                    reason: prepared.isGap ? "source_clock_unknown" : nil,
                                    coverage: prepared.isGap ? "excluded" : nil)
        var candidate = state
        candidate.checkpoints.append(checkpoint)
        // Refuse a full journal before admitting any new outbound bytes.
        let encoded = try encode(candidate)
        if !prepared.isGap {
            _ = try outbox.enqueue(sourceRecordRef: prepared.sourceRecordRef, revision: prepared.revisionRef) { source, id in
                guard let envelope = try prepared.envelope(sourceUUID: source, externalID: id) else { throw Failure.invalidState }
                return envelope
            }
        }
        do { try persist(encoded) }
        catch { storageFailed = true; throw error }
        state = candidate
        return checkpoint
    }

    private func encode(_ value: State) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= maxControlBytes else { throw Failure.capacityExceeded }
        return encoded
    }

    private static func valid(_ value: State) -> Bool {
        guard (value.scans ?? [:]).allSatisfy({ validSession($0.key) && validScan($0.value) }) else { return false }
        for (id, u) in value.uploads ?? [:] {
            guard !u.sourceRecordRef.isEmpty, !u.revision.isEmpty, !u.pipeline.isEmpty,
                  u.bodySHA256.count == 64, u.bodySHA256.allSatisfy({ $0.isHexDigit }),
                  u.original.byteLength > 0,
                  (try? AudioHubOutbox.OriginalReference(sourceRelativePath: u.original.sourceRelativePath,
                      sha256: u.original.sha256, byteLength: u.original.byteLength)) == u.original,
                  AudioHubOutbox.externalID(sourceUUID: value.sourceUUID, sourceRecordRef: u.sourceRecordRef,
                                           revision: u.revision) == id,
                  u.offset >= 0, u.offset <= u.original.byteLength,
                  (u.gapReason == nil && u.gapCoverage == nil) ||
                    ((u.gapReason == "source_original_missing" || u.gapReason == "source_original_changed") &&
                     u.gapCoverage == "excluded") else { return false }
            if let uploadID = u.uploadID {
                guard UUID(uuidString: uploadID)?.uuidString.lowercased() == uploadID else { return false }
            } else if u.offset != 0 || u.finalized { return false }
            if u.finalized && u.offset != u.original.byteLength { return false }
            if let binding = u.binding {
                guard u.finalized, UUID(uuidString: binding.eventID)?.uuidString.lowercased() == binding.eventID,
                      let job = binding.jobID, UUID(uuidString: job)?.uuidString.lowercased() == job,
                      binding.pipelineVersion == u.pipeline else { return false }
            }
        }
        var ids = Set<String>()
        for checkpoint in value.checkpoints {
            guard !checkpoint.sourceRecordRef.isEmpty,
                  checkpoint.revisionRef.hasPrefix("sha256:"), checkpoint.revisionRef.count == 71,
                  checkpoint.revisionRef.dropFirst(7).allSatisfy({ $0.isHexDigit }) else { return false }
            let id = AudioHubOutbox.externalID(sourceUUID: value.sourceUUID,
                                               sourceRecordRef: checkpoint.sourceRecordRef, revision: checkpoint.revisionRef)
            guard ids.insert(id).inserted else { return false }
            switch checkpoint.disposition {
            case "enqueued":
                guard checkpoint.externalID == id, checkpoint.reason == nil, checkpoint.coverage == nil else { return false }
            case "excluded":
                guard checkpoint.externalID == nil, checkpoint.reason == "source_clock_unknown",
                      checkpoint.coverage == "excluded" else { return false }
            default: return false
            }
        }
        return true
    }

    private static func validSession(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.unicodeScalars.contains {
            $0 == "/" || $0 == "\\" || $0 == ":" || CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func validCursor(_ value: AudioHubRawTranscriptReader.Checkpoint) -> Bool {
        guard let snapshot = value.snapshot, snapshot.length <= UInt64(Int64.max),
              value.offset <= snapshot.length, value.physicalLine < UInt64(Int.max) else { return false }
        return value.offset == 0 ? value.physicalLine == 0 : value.physicalLine > 0 && value.physicalLine <= value.offset
    }

    private static func validScan(_ scan: Scan) -> Bool {
        guard validCursor(scan.initial), validCursor(scan.cursor),
              scan.cursor.offset >= scan.initial.offset,
              scan.cursor.physicalLine >= scan.initial.physicalLine,
              scan.cursor.snapshot?.device == scan.initial.snapshot?.device,
              scan.cursor.snapshot?.inode == scan.initial.snapshot?.inode else { return false }
        guard let line = scan.staged else { return true }
        return !line.rawLine.isEmpty && line.rawLine.last == 0x0A &&
            line.rawLine.dropLast().contains(0x0A) == false &&
            line.physicalLine == scan.cursor.physicalLine + 1 &&
            line.nextPhysicalLine == line.physicalLine && line.physicalLine < UInt64(Int.max) &&
            line.nextOffset > scan.cursor.offset &&
            line.nextOffset - scan.cursor.offset == UInt64(line.rawLine.count) &&
            line.nextOffset <= line.snapshot.length && line.snapshot.length <= UInt64(Int64.max) &&
            line.snapshot.length >= (scan.cursor.snapshot?.length ?? 0) &&
            line.snapshot.device == scan.cursor.snapshot?.device && line.snapshot.inode == scan.cursor.snapshot?.inode
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func persist(_ data: Data) throws {
        let lockURL = stateURL.deletingLastPathComponent().appendingPathComponent(".control.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.storageFailed }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.storageFailed }
        defer { flock(fd, LOCK_UN) }
        let currentFD = open(stateURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        var currentHash: String?
        if currentFD >= 0 {
            let current = FileHandle(fileDescriptor: currentFD, closeOnDealloc: true)
            defer { try? current.close() }
            guard fstat(currentFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
                  info.st_size <= maxControlBytes else { throw Failure.invalidState }
            let bytes = try current.read(upToCount: maxControlBytes + 1) ?? Data()
            guard bytes.count <= maxControlBytes else { throw Failure.invalidState }
            currentHash = Self.hash(bytes)
        } else if errno != ENOENT { throw Failure.storageFailed }
        guard currentHash == persistedHash else { throw Failure.staleWriter }
        let temporary = stateURL.deletingLastPathComponent().appendingPathComponent(".control-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.storageFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: data)
        guard fsync(descriptor) == 0, rename(temporary.path, stateURL.path) == 0 else { throw Failure.storageFailed }
        let directory = open(stateURL.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw Failure.storageFailed }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw Failure.storageFailed }
        persistedHash = Self.hash(data)
    }
}
