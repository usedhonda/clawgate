import Foundation
import Darwin

/// Inactive source-admission journal, not a delivery ACK or a scan-position cursor.
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
        case invalidBudget, invalidState, capacityExceeded, storageFailed, wrongSource
    }

    private struct State: Codable {
        let version: Int
        let sourceUUID: String
        var checkpoints: [Checkpoint]
    }

    private let stateURL: URL
    private let maxControlBytes: Int
    private let lock = NSLock()
    private var state: State
    private var storageFailed = false

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
        } else {
            guard errno == ENOENT else { throw Failure.invalidState }
            try persist(try encode(state))
        }
    }

    func checkpoints() throws -> [Checkpoint] {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Failure.storageFailed }
        return state.checkpoints
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

    private func persist(_ data: Data) throws {
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
    }
}
