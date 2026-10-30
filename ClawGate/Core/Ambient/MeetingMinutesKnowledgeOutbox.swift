import Darwin
import Foundation

/// Ordered producer ledger, not a consumer store. Reuses the existing private,
/// bounded, fsynced file primitives. Never activated by constructing a snapshot.
final class MeetingMinutesKnowledgeOutbox {
    typealias Failure = AudioHubOutbox.Error
    private struct Entry: Codable {
        let operation: MeetingMinutesPublication.Operation
        let meetingID: String
        let outputRevision: String
        let ordinal: Int
        let previousRevision: String?
        let selectionBasis: MeetingMinutesPublication.SelectionBasis
        let payloadSHA256: String
        let envelopeSHA256: String
        var payload: Data?
        var receipt: MeetingMinutesPublicationReceipt?

        func envelope(sourceUUID: String) -> MeetingMinutesPublication? {
            guard let payload else { return nil }
            return MeetingMinutesPublication(schemaVersion: 1, operation: operation,
                sourceUUID: sourceUUID, meetingID: meetingID, outputRevision: outputRevision,
                publicationOrdinal: ordinal, previousRevision: previousRevision,
                selectionBasis: selectionBasis, payloadSHA256: payloadSHA256,
                payloadBase64: payload.base64EncodedString())
        }
        var settled: Bool {
            guard let status = receipt?.status else { return false }
            return status == .stored || status == .searchable || status == .deleted
        }
    }
    private struct State: Codable {
        let format: String
        let sourceUUID: String
        var entries: [Entry]
    }
    let directory: URL
    let sourceUUID: String
    private let maxMetadataBytes: Int
    private var state: State
    private var durableDigest: String
    private var failed = false
    private let lock = NSLock()
    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    init(store: MeetingStore, maxMetadataBytes: Int) throws {
        guard maxMetadataBytes > 0, maxMetadataBytes < Int.max else { throw Failure.invalidMaxMetadataBytes }
        directory = store.root.appendingPathComponent("knowledge-outbox", isDirectory: true)
        self.maxMetadataBytes = maxMetadataBytes
        let url = directory.appendingPathComponent("state.json")
        let loaded: (State, String) = try Self.withFileLock(directory) {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try AudioHubOutbox.readBounded(url, maxBytes: maxMetadataBytes)
                let value: State
                do { value = try JSONDecoder().decode(State.self, from: data) }
                catch { throw Failure.corruptState }
                guard value.format == "minutes-publication-v1",
                      UUID(uuidString: value.sourceUUID)?.uuidString.lowercased() == value.sourceUUID else {
                    throw Failure.corruptState
                }
                var heads: [String: Entry] = [:]
                for entry in value.entries {
                    let head = heads[entry.meetingID]
                    guard entry.ordinal == (head?.ordinal ?? 0) + 1,
                          entry.previousRevision == head?.outputRevision,
                          !entry.meetingID.isEmpty, !entry.outputRevision.isEmpty else { throw Failure.corruptState }
                    if let envelope = entry.envelope(sourceUUID: value.sourceUUID) {
                        guard MeetingMinutesPublication.digest(entry.payload!) == entry.payloadSHA256,
                              MeetingMinutesPublication.digest(try envelope.encoded()) == entry.envelopeSHA256 else {
                            throw Failure.corruptState
                        }
                    } else if !entry.settled { throw Failure.corruptState }
                    if let receipt = entry.receipt {
                        guard receipt.sourceUUID == value.sourceUUID, receipt.meetingID == entry.meetingID,
                              receipt.publicationOrdinal == entry.ordinal, receipt.outputRevision == entry.outputRevision,
                              receipt.payloadSHA256 == entry.payloadSHA256, receipt.schemaVersion == 1 else {
                            throw Failure.corruptState
                        }
                    }
                    heads[entry.meetingID] = entry
                }
                return (value, MeetingMinutesPublication.digest(data))
            }
            let value = State(format: "minutes-publication-v1", sourceUUID: UUID().uuidString.lowercased(), entries: [])
            return (value, try AudioHubOutbox.persist(value, to: url, maxBytes: maxMetadataBytes))
        }
        state = loaded.0; sourceUUID = loaded.0.sourceUUID; durableDigest = loaded.1
    }

    @discardableResult
    func enqueue(acceptedData: Data, record: MeetingRecord,
                 explicitlySelected: Bool = false) throws -> MeetingMinutesKnowledgeSnapshot {
        let snapshot = try MeetingMinutesKnowledgeSnapshot(acceptedData: acceptedData,
            record: record, explicitlySelected: explicitlySelected)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(snapshot)
        lock.lock(); defer { lock.unlock() }
        try ensureCurrent()
        let entries = state.entries.filter { $0.meetingID == record.id }
        // Consumer tombstones are terminal. Re-enabling this slot requires a
        // separate explicit protocol, not a new automatically generated hash.
        guard entries.last?.operation != .delete else { throw Failure.conflict }
        if let existing = entries.first(where: { $0.operation == .upsert && $0.outputRevision == snapshot.outputRevision }) {
            // Reconciliation may never resurrect a revision behind a tombstone.
            if let deletion = entries.last(where: { $0.operation == .delete }), deletion.ordinal > existing.ordinal {
                throw Failure.conflict
            }
            guard existing.payloadSHA256 == MeetingMinutesPublication.digest(payload) else { throw Failure.conflict }
            return snapshot
        }
        try append(operation: .upsert, meetingID: record.id, revision: snapshot.outputRevision,
                   selection: explicitlySelected ? .explicitHistory : .futureAccepted, payload: payload)
        return snapshot
    }

    /// Only a caller handling an explicit source deletion may invoke this.
    /// No enumeration miss, failed read, or old receipt invokes it automatically.
    func enqueueDeletion(meetingID: String, expectedRevision: String) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureCurrent()
        guard let head = state.entries.last(where: { $0.meetingID == meetingID }),
              head.outputRevision == expectedRevision else { throw Failure.conflict }
        if head.operation == .delete { return }
        try append(operation: .delete, meetingID: meetingID, revision: head.outputRevision,
                   selection: head.selectionBasis, payload: Data())
    }

    private func append(operation: MeetingMinutesPublication.Operation, meetingID: String,
                        revision: String, selection: MeetingMinutesPublication.SelectionBasis, payload: Data) throws {
        let head = state.entries.last { $0.meetingID == meetingID }
        guard (head?.ordinal ?? 0) < Int.max else { throw Failure.capacityExceeded }
        let envelope = MeetingMinutesPublication(schemaVersion: 1, operation: operation,
            sourceUUID: sourceUUID, meetingID: meetingID, outputRevision: revision,
            publicationOrdinal: (head?.ordinal ?? 0) + 1, previousRevision: head?.outputRevision,
            selectionBasis: selection, payloadSHA256: MeetingMinutesPublication.digest(payload),
            payloadBase64: payload.base64EncodedString())
        let entry = Entry(operation: operation, meetingID: meetingID, outputRevision: revision,
            ordinal: envelope.publicationOrdinal, previousRevision: head?.outputRevision,
            selectionBasis: selection, payloadSHA256: envelope.payloadSHA256,
            envelopeSHA256: MeetingMinutesPublication.digest(try envelope.encoded()), payload: payload)
        var next = state; next.entries.append(entry)
        try persist(next)
    }

    /// Delivery-pending only; stored is settled but can still await indexing.
    func publications() throws -> [MeetingMinutesPublication] {
        lock.lock(); defer { lock.unlock() }; try ensureCurrent()
        return state.entries.filter { !$0.settled }.compactMap { $0.envelope(sourceUUID: sourceUUID) }
    }

    /// Exact envelope progress queries. Bodies are retained only until terminal
    /// search acceptance/non-current receipt, never as an extra version archive.
    func awaitingSearchability() throws -> [MeetingMinutesPublication] {
        lock.lock(); defer { lock.unlock() }; try ensureCurrent()
        return state.entries.filter { $0.receipt?.status == .stored && $0.receipt?.isCurrent == true }
            .compactMap { $0.envelope(sourceUUID: sourceUUID) }
    }

    func pending() throws -> [MeetingMinutesKnowledgeSnapshot] {
        try publications().filter { $0.operation == .upsert }.map {
            guard let data = Data(base64Encoded: $0.payloadBase64) else { throw Failure.corruptState }
            return try JSONDecoder().decode(MeetingMinutesKnowledgeSnapshot.self, from: data)
        }
    }

    func receive(_ receipt: MeetingMinutesPublicationReceipt, expected: MeetingMinutesPublication) throws {
        lock.lock(); defer { lock.unlock() }; try ensureCurrent()
        guard receipt.matches(expected), let index = state.entries.firstIndex(where: {
            $0.meetingID == expected.meetingID && $0.ordinal == expected.publicationOrdinal
        }), state.entries[index].envelopeSHA256 == MeetingMinutesPublication.digest(try expected.encoded()) else {
            throw Failure.payloadMismatch
        }
        guard receipt.status == .stored || receipt.status == .searchable || receipt.status == .deleted else {
            // Rejection/gap is not a delivery ACK and must not erase pending.
            return
        }
        guard (expected.operation == .delete) == (receipt.status == .deleted),
              receipt.status != .searchable || receipt.isCurrent else { throw Failure.payloadMismatch }
        var next = state
        // A delayed stored receipt cannot regress a previous searchable/deleted
        // proof or re-expose a body already compacted from this ledger.
        if let old = next.entries[index].receipt,
           (old.status == .searchable || old.status == .deleted || !old.isCurrent),
           receipt.status == .stored && receipt.isCurrent { return }
        next.entries[index].receipt = receipt
        if receipt.status == .searchable || receipt.status == .deleted || !receipt.isCurrent {
            next.entries[index].payload = nil
        }
        try persist(next)
    }

    func reconcile(store: MeetingStore, records: [MeetingRecord]) throws {
        for record in records {
            if try isDeleted(meetingID: record.id) { continue }
            let url = store.directory(for: record.id).appendingPathComponent("minutes-accepted.json")
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch CocoaError.fileReadNoSuchFile { continue }
            do { try enqueue(acceptedData: data, record: record) }
            catch MeetingMinutesKnowledgeSnapshot.SnapshotError.historicalSelectionRequired { continue }
        }
    }

    private func isDeleted(meetingID: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }; try ensureCurrent()
        return state.entries.last(where: { $0.meetingID == meetingID })?.operation == .delete
    }

    private func ensureCurrent() throws {
        guard !failed else { throw Failure.ioFailure }
        let bytes = try AudioHubOutbox.readBounded(stateURL, maxBytes: maxMetadataBytes)
        guard MeetingMinutesPublication.digest(bytes) == durableDigest else { throw Failure.conflict }
    }

    private func persist(_ candidate: State) throws {
        do {
            try Self.withFileLock(directory) {
                try ensureCurrent()
                durableDigest = try AudioHubOutbox.persist(candidate, to: stateURL, maxBytes: maxMetadataBytes)
            }
            state = candidate
        } catch Failure.capacityExceeded { throw Failure.capacityExceeded
        } catch Failure.conflict { throw Failure.conflict
        } catch { failed = true; throw error }
    }

    private static func withFileLock<T>(_ directory: URL, _ action: () throws -> T) throws -> T {
        try AudioHubOutbox.ensureDirectory(directory)
        let fd = open(directory.appendingPathComponent(".state.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.ioFailure }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.ioFailure }
        defer { _ = flock(fd, LOCK_UN) }
        return try action()
    }
}
