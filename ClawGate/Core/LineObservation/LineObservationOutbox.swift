import Foundation

/// A small, durable FIFO for passive LINE observations.
///
/// Payloads are intentionally opaque: the caller owns the observation schema and
/// this type only guarantees durable storage and delivery ordering.
public final class LineObservationOutbox {
    public enum OutboxError: Error, LocalizedError, Equatable {
        case invalidDirectory
        case invalidIdentifier(String)
        case capacityExceeded(required: Int, available: Int)
        case unknownIdentifier(String)
        case payloadConflict(String)
        case corruptState
        case corruptRecord(String)

        public var errorDescription: String? {
            switch self {
            case .invalidDirectory: return "LINE observation outbox directory is not usable"
            case .invalidIdentifier(let id): return "Invalid LINE observation identifier: \(id)"
            case .capacityExceeded(let required, let available):
                return "LINE observation outbox capacity exceeded (required \(required) bytes, available \(available) bytes)"
            case .unknownIdentifier(let id): return "Unknown LINE observation identifier: \(id)"
            case .payloadConflict(let id): return "LINE observation payload conflicts with an already queued identifier: \(id)"
            case .corruptState: return "LINE observation outbox state is corrupt"
            case .corruptRecord(let id): return "LINE observation outbox record is corrupt: \(id)"
            }
        }
    }

    private struct Record: Codable, Equatable {
        let id: String
        let sequence: Int64
        let byteCount: Int
    }

    private struct State: Codable {
        var producerInstance: String
        var nextSequence: Int64
        var records: [Record]
        var allocated: [String: Int64]
        var acknowledgedFiles: [String]?
        var rejectedRecords: [String: String]?
    }

    private let directory: URL
    private let stateURL: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private var state: State
    private var bytes: Int

    public init(directory: URL, maxBytes: Int = 256 * 1024 * 1024) throws {
        guard maxBytes > 0 else { throw OutboxError.capacityExceeded(required: 1, available: maxBytes) }
        self.directory = directory
        self.stateURL = directory.appendingPathComponent("state.json", isDirectory: false)
        self.maxBytes = maxBytes

        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard manager.fileExists(atPath: directory.path) else { throw OutboxError.invalidDirectory }
        chmod(directory.path, 0o700)

        if manager.fileExists(atPath: stateURL.path) {
            do {
                let data = try Data(contentsOf: stateURL)
                self.state = try JSONDecoder().decode(State.self, from: data)
            } catch {
                throw OutboxError.corruptState
            }
        } else {
            self.state = State(producerInstance: UUID().uuidString.lowercased(), nextSequence: 0, records: [], allocated: [:])
        }
        guard UUID(uuidString: state.producerInstance) != nil,
              state.nextSequence >= 0,
              Set(state.records.map(\.id)).count == state.records.count,
              state.records.allSatisfy({ Self.isSafeIdentifier($0.id) && $0.byteCount >= 0 }) else {
            throw OutboxError.corruptState
        }
        self.bytes = state.records.reduce(0) { $0 + $1.byteCount }
        let indexedFiles = Set(state.records.map { recordURL(for: $0.id).lastPathComponent })
        let orphanFiles = try manager.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasPrefix("record-") && $0.hasSuffix(".bin") && !indexedFiles.contains($0)
        }
        for acknowledged in state.acknowledgedFiles ?? [] {
            guard Self.isSafeIdentifier(acknowledged) else { throw OutboxError.corruptState }
            try? manager.removeItem(at: recordURL(for: acknowledged))
        }
        let unresolved = orphanFiles.filter { file in
            !(state.acknowledgedFiles ?? []).contains(String(file.dropFirst("record-".count).dropLast(".bin".count)))
        }
        if let orphan = unresolved.first {
            let id = String(orphan.dropFirst("record-".count).dropLast(".bin".count))
            throw OutboxError.corruptRecord(id)
        }
        try persistStateIfNeeded()
        for record in state.records { chmod(recordURL(for: record.id).path, 0o600) }
    }

    public var queuedCount: Int { lock.lock(); defer { lock.unlock() }; return state.records.count }
    public var queuedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    public var rejectedCount: Int { lock.lock(); defer { lock.unlock() }; return state.rejectedRecords?.count ?? 0 }
    public var producerInstance: String { lock.lock(); defer { lock.unlock() }; return state.producerInstance }

    /// Allocates a producer-scoped, monotonic identifier and persists the increment
    /// before returning, so reopening the outbox cannot reuse the sequence.
    public func allocateID() throws -> (id: String, seq: Int64) {
        lock.lock(); defer { lock.unlock() }
        let sequence = state.nextSequence
        let id = "line:\(state.producerInstance):\(sequence)"
        state.nextSequence += 1
        state.allocated[id] = sequence
        try persistState()
        return (id, sequence)
    }

    public func enqueue(_ payload: Data, observationID: String) throws {
        guard Self.isSafeIdentifier(observationID) else { throw OutboxError.invalidIdentifier(observationID) }
        lock.lock(); defer { lock.unlock() }
        if let existing = state.records.first(where: { $0.id == observationID }) {
            guard let current = try? Data(contentsOf: recordURL(for: observationID)),
                  current.count == existing.byteCount else { throw OutboxError.corruptRecord(observationID) }
            if current != payload { throw OutboxError.payloadConflict(observationID) }
            return
        }
        let available = maxBytes - bytes
        guard payload.count <= available else {
            state.allocated.removeValue(forKey: observationID)
            try? persistState()
            throw OutboxError.capacityExceeded(required: payload.count, available: max(0, available))
        }
        let sequence: Int64
        if let allocated = state.allocated.removeValue(forKey: observationID) {
            sequence = allocated
        } else {
            sequence = state.nextSequence
            state.nextSequence += 1
        }
        let record = Record(id: observationID, sequence: sequence, byteCount: payload.count)
        try atomicWrite(payload, to: recordURL(for: observationID), permissions: 0o600)
        state.records.append(record)
        state.records.sort { $0.sequence < $1.sequence }
        bytes += payload.count
        do {
            try persistState()
        } catch {
            // Keep the payload and state recoverable for a later retry; the record
            // is not acknowledged or silently discarded.
            state.records.removeAll { $0.id == observationID }
            bytes -= payload.count
            throw error
        }
    }

    public func pending(limit: Int = 20) throws -> [(id: String, data: Data)] {
        guard limit >= 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        var result: [(id: String, data: Data)] = []
        for record in state.records.filter({ state.rejectedRecords?[$0.id] == nil }).prefix(limit) {
            let url = recordURL(for: record.id)
            do {
                let data = try Data(contentsOf: url)
                guard data.count == record.byteCount else { throw OutboxError.corruptRecord(record.id) }
                result.append((record.id, data))
            } catch let error as OutboxError { throw error }
            catch { throw OutboxError.corruptRecord(record.id) }
        }
        return result
    }

    /// A permanent server rejection is retained for inspection, never acknowledged
    /// or silently dropped; later valid observations must not starve behind it.
    public func markRejected(_ ids: [String], code: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard ids.allSatisfy({ id in state.records.contains { $0.id == id } }) else { throw OutboxError.corruptState }
        let before = state
        var rejected = state.rejectedRecords ?? [:]
        for id in ids { rejected[id] = String(code.prefix(80)) }
        state.rejectedRecords = rejected
        do { try persistState() } catch { state = before; throw error }
    }

    public func acknowledge(_ ids: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        let unique = Array(Set(ids))
        for id in unique {
            guard Self.isSafeIdentifier(id), state.records.contains(where: { $0.id == id }) else {
                throw OutboxError.unknownIdentifier(id)
            }
        }
        let before = state
        let previousBytes = bytes
        let removed = state.records.filter { unique.contains($0.id) }
        state.acknowledgedFiles = Array(Set((state.acknowledgedFiles ?? []) + removed.map(\.id)))
        state.records.removeAll { unique.contains($0.id) }
        bytes -= removed.reduce(0) { $0 + $1.byteCount }
        do { try persistState() } catch { state = before; bytes = previousBytes; throw error }
        // Persist the dequeue before deleting payloads; a crash cannot leave an
        // indexed record whose payload has already disappeared.
        for record in removed { try? FileManager.default.removeItem(at: recordURL(for: record.id)) }
        state.acknowledgedFiles = (state.acknowledgedFiles ?? []).filter { FileManager.default.fileExists(atPath: recordURL(for: $0).path) }
        try? persistState()
    }

    private func recordURL(for id: String) -> URL { directory.appendingPathComponent("record-\(id).bin", isDirectory: false) }

    private func persistStateIfNeeded() throws {
        if !FileManager.default.fileExists(atPath: stateURL.path) { try persistState() }
    }

    private func persistState() throws {
        let data = try JSONEncoder().encode(state)
        try atomicWrite(data, to: stateURL, permissions: 0o600)
    }

    private func atomicWrite(_ data: Data, to url: URL, permissions: mode_t) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        chmod(temp.path, permissions)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
        chmod(url.path, permissions)
    }

    private static func isSafeIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 200 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122) || scalar == "-" || scalar == "_" || scalar == "." || scalar == ":"
        }
    }
}
