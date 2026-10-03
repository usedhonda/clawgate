import CryptoKit
import Darwin
import Foundation

/// Durable metadata-only handoff for a future native audio producer.
/// This type is intentionally inactive: no producer or transport is started here.
final class AudioHubOutbox {
    struct OriginalReference: Codable, Equatable {
        let sourceRelativePath: String
        let sha256: String
        let byteLength: Int64

        init(sourceRelativePath: String, sha256: String, byteLength: Int64) throws {
            guard AudioHubOutbox.isSelectedMeetingAudioPath(sourceRelativePath),
                  sha256.count == 64,
                  sha256.allSatisfy({ $0.isHexDigit }),
                  byteLength >= 0 else { throw Error.invalidOriginalReference }
            self.sourceRelativePath = sourceRelativePath
            self.sha256 = sha256.lowercased()
            self.byteLength = byteLength
        }
    }

    struct PendingRecord: Codable, Equatable {
        let externalID: String
        let sourceRecordRef: String
        let revision: String
        let envelope: Data
        let bodySHA256: String
        let original: OriginalReference?
    }

    enum Error: Swift.Error, Equatable {
        case invalidMaxMetadataBytes
        case corruptState
        case invalidSourceRecord
        case invalidOriginalReference
        case conflict
        case missingRecord
        case payloadMismatch
        case capacityExceeded
        case ioFailure
    }

    private struct Acknowledgement: Codable, Equatable {
        let externalID: String
        let receipt: Data
    }

    private struct State: Codable, Equatable {
        let version: Int
        let sourceUUID: String
        var pending: [PendingRecord]
        var latestAcknowledgement: Acknowledgement?
    }

    let sourceUUID: String
    private let directory: URL
    private let maxMetadataBytes: Int
    private let stateURL: URL
    private var state: State
    // An ambiguous disk commit must be reopened before any further mutation.
    private var storageFailed = false
    private let lock = NSLock()

    init(directory: URL, maxMetadataBytes: Int, sourceUUID: String = UUID().uuidString.lowercased()) throws {
        guard maxMetadataBytes > 0 else { throw Error.invalidMaxMetadataBytes }
        self.directory = directory
        self.maxMetadataBytes = maxMetadataBytes
        self.stateURL = directory.appendingPathComponent("state.json")

        do {
            try Self.ensureDirectory(directory)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                      let size = attributes[.size] as? NSNumber, size.intValue <= maxMetadataBytes else { throw Error.corruptState }
                let data = try Data(contentsOf: stateURL)
                let loaded = try JSONDecoder().decode(State.self, from: data)
                guard loaded.version == 1, UUID(uuidString: loaded.sourceUUID)?.uuidString.lowercased() == loaded.sourceUUID,
                      Set(loaded.pending.map(\.externalID)).count == loaded.pending.count,
                      loaded.pending.allSatisfy({ record in
                          !record.sourceRecordRef.isEmpty && !record.revision.isEmpty &&
                          Self.externalID(sourceUUID: loaded.sourceUUID,
                                          sourceRecordRef: record.sourceRecordRef,
                                          revision: record.revision) == record.externalID &&
                          !record.sourceRecordRef.isEmpty && !record.revision.isEmpty &&
                          record.externalID == Self.externalID(sourceUUID: loaded.sourceUUID, sourceRecordRef: record.sourceRecordRef, revision: record.revision) &&
                          Self.sha256(record.envelope) == record.bodySHA256 &&
                          (record.original == nil || Self.validOriginal(record.original!))
                      }) else { throw Error.corruptState }
                self.state = loaded
                self.sourceUUID = loaded.sourceUUID
            } else {
                guard UUID(uuidString: sourceUUID)?.uuidString.lowercased() == sourceUUID else { throw Error.invalidSourceRecord }
                self.sourceUUID = sourceUUID
                self.state = State(version: 1, sourceUUID: sourceUUID, pending: [], latestAcknowledgement: nil)
                try Self.persist(self.state, to: stateURL, maxBytes: maxMetadataBytes)
            }
        } catch let error as Error {
            throw error
        } catch {
            throw Error.corruptState
        }
    }

    func pending(limit: Int) throws -> [PendingRecord] {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Error.ioFailure }
        guard limit >= 0 else { return [] }
        return Array(state.pending.prefix(limit))
    }

    /// Enqueues only the immutable envelope and optional metadata; the referenced audio is never opened or copied.
    @discardableResult
    func enqueue(sourceRecordRef: String, revision: String, original: OriginalReference? = nil,
                 make: (String, String) throws -> Data) throws -> String {
        guard !sourceRecordRef.isEmpty, !revision.isEmpty else { throw Error.invalidSourceRecord }
        let externalID = Self.externalID(sourceUUID: sourceUUID, sourceRecordRef: sourceRecordRef, revision: revision)
        let body = try make(sourceUUID, externalID)
        let record = PendingRecord(externalID: externalID, sourceRecordRef: sourceRecordRef,
                                   revision: revision, envelope: body,
                                   bodySHA256: Self.sha256(body), original: original)
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Error.ioFailure }
        if let existing = state.pending.first(where: { $0.externalID == externalID }) {
            guard existing.envelope == body, existing.original == original else { throw Error.conflict }
            return externalID
        }
        var candidate = state
        candidate.pending.append(record)
        try persistCandidate(candidate)
        state = candidate
        return externalID
    }

    /// Parent validates receipt semantics before calling this method. The snapshot payload must match exactly.
    func acknowledge(externalID: String, expectedEnvelope: Data, receipt: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !storageFailed else { throw Error.ioFailure }
        guard let index = state.pending.firstIndex(where: { $0.externalID == externalID }) else { throw Error.missingRecord }
        let record = state.pending[index]
        guard record.envelope == expectedEnvelope,
              record.bodySHA256 == Self.sha256(expectedEnvelope) else { throw Error.payloadMismatch }
        var candidate = state
        candidate.pending.remove(at: index)
        candidate.latestAcknowledgement = Acknowledgement(externalID: externalID, receipt: receipt)
        try persistCandidate(candidate)
        state = candidate
    }

    private func persistCandidate(_ candidate: State) throws {
        do { try Self.persist(candidate, to: stateURL, maxBytes: maxMetadataBytes) }
        catch Error.capacityExceeded { throw Error.capacityExceeded }
        catch { storageFailed = true; throw error }
    }

    private static func externalID(sourceUUID: String, sourceRecordRef: String, revision: String) -> String {
        var input = Data()
        for value in [sourceRecordRef, revision] {
            var length = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(contentsOf: value.utf8)
        }
        return "clawgate:native:v1:\(sourceUUID):\(sha256(input))"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Error.corruptState }
        guard chmod(directory.path, mode_t(0o700)) == 0 else { throw Error.ioFailure }
    }

    private static func persist(_ state: State, to url: URL, maxBytes: Int) throws {
        let data: Data
        do { data = try JSONEncoder().encode(state) } catch { throw Error.ioFailure }
        guard data.count <= maxBytes else { throw Error.capacityExceeded }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".state-\(UUID().uuidString).tmp")
        do {
            FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                            attributes: [.posixPermissions: NSNumber(value: 0o600)])
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard fsync(handle.fileDescriptor) == 0 else { throw Error.ioFailure }
            try handle.close()
            guard chmod(temporary.path, mode_t(0o600)) == 0 else { throw Error.ioFailure }
            guard rename(temporary.path, url.path) == 0 else { throw Error.ioFailure }
            guard chmod(url.path, mode_t(0o600)) == 0 else { throw Error.ioFailure }
            let directoryFD = open(url.deletingLastPathComponent().path, O_RDONLY)
            guard directoryFD >= 0 else { throw Error.ioFailure }
            defer { close(directoryFD) }
            guard fsync(directoryFD) == 0 else { throw Error.ioFailure }
        } catch let error as Error { try? FileManager.default.removeItem(at: temporary); throw error
        } catch { try? FileManager.default.removeItem(at: temporary); throw Error.ioFailure }
    }

    private static func isSelectedMeetingAudioPath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "meetings", parts[2] == "audio" else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func validOriginal(_ original: OriginalReference) -> Bool {
        isSelectedMeetingAudioPath(original.sourceRelativePath) &&
            original.sha256.count == 64 && original.sha256.allSatisfy({ $0.isHexDigit }) &&
            original.byteLength >= 0
    }
}
