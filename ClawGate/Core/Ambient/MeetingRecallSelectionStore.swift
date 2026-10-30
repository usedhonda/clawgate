import Foundation

/// Only the owner's chosen event references, never transcript bodies or a
/// reusable permission. Every generation still needs a fresh canonical read.
struct MeetingRecallSelectionStore {
    struct Item: Codable, Equatable {
        let eventID: String
        /// Optional explicitly chosen derived Hub event, not its resultId.
        let resultEventID: String?
        var kind: String? = nil
    }
    struct Snapshot {
        let items: [Item]
        let fingerprint: String?
    }
    enum SelectionError: Error { case invalid, changed }
    private struct Manifest: Codable {
        let schemaVersion: Int
        let meetingID: String
        let items: [Item]
    }
    private static let lock = NSLock()
    private let store: MeetingStore
    private let metadataLimit = 64 * 1024

    init(store: MeetingStore) { self.store = store }

    func load(meetingID: String) throws -> Snapshot {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read(meetingID: meetingID)
    }

    @discardableResult
    func save(items: [Item], record: MeetingRecord, expectedFingerprint: String?) throws -> Snapshot {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = try file(meetingID: record.id)
        guard store.load(id: record.id) == record, Self.valid(items) else { throw SelectionError.invalid }
        let current = try read(meetingID: record.id)
        guard current.fingerprint == expectedFingerprint else { throw SelectionError.changed }
        if current.items == items, current.fingerprint != nil { return current }
        try AudioHubOutbox.ensureDirectory(url.deletingLastPathComponent())
        let digest = try AudioHubOutbox.persist(Manifest(schemaVersion: 1, meetingID: record.id, items: items),
            to: url, maxBytes: metadataLimit)
        return Snapshot(items: items, fingerprint: "sha256:" + digest)
    }

    private func read(meetingID: String) throws -> Snapshot {
        let url = try file(meetingID: meetingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot(items: [], fingerprint: nil) }
        let data = try AudioHubOutbox.readBounded(url, maxBytes: metadataLimit)
        let value = try JSONDecoder().decode(Manifest.self, from: data)
        guard value.schemaVersion == 1, value.meetingID == meetingID, Self.valid(value.items) else {
            throw SelectionError.invalid
        }
        return Snapshot(items: value.items, fingerprint: "sha256:" + MeetingMinutesPublication.digest(data))
    }

    private func file(meetingID: String) throws -> URL {
        guard !meetingID.isEmpty, meetingID != ".", meetingID != "..",
              !meetingID.contains("/"), !meetingID.contains("\0") else { throw SelectionError.invalid }
        return store.directory(for: meetingID).appendingPathComponent("recall-selection.json")
    }

    private static func valid(_ items: [Item]) -> Bool {
        Set(items.map(\.eventID)).count == items.count && items.allSatisfy {
            ($0.kind == nil || MeetingRecallReadBridge.Kind(rawValue: $0.kind!) != nil) &&
            UUID(uuidString: $0.eventID) != nil && ($0.resultEventID == nil ||
                ($0.resultEventID != $0.eventID && UUID(uuidString: $0.resultEventID!) != nil))
        }
    }
}
