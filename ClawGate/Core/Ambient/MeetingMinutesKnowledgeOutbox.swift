import Foundation
import CryptoKit

/// Local producer staging only. Enqueuing is not consumer storage or indexing.
/// The accepted document remains authoritative if staging fails or is interrupted.
struct MeetingMinutesKnowledgeOutbox {
    let directory: URL

    init(store: MeetingStore) {
        directory = store.root.appendingPathComponent("knowledge-outbox", isDirectory: true)
    }

    enum QueueError: Error, Equatable {
        case immutableConflict
    }

    @discardableResult
    func enqueue(acceptedData: Data, record: MeetingRecord,
                 explicitlySelected: Bool = false) throws -> MeetingMinutesKnowledgeSnapshot {
        let snapshot = try MeetingMinutesKnowledgeSnapshot(acceptedData: acceptedData,
            record: record, explicitlySelected: explicitlySelected)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(snapshot)
        let url = pendingURL(meetingID: snapshot.context.meetingID, outputRevision: snapshot.outputRevision)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // link publishes a fully written, private payload without replacing a
        // concurrent writer's binding for this meeting/revision.
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".pending")
        try payload.write(to: temporary, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        do {
            try FileManager.default.linkItem(at: temporary, to: url)
        } catch CocoaError.fileWriteFileExists {
            guard try Data(contentsOf: url) == payload else { throw QueueError.immutableConflict }
        }
        return snapshot
    }

    func pending() throws -> [MeetingMinutesKnowledgeSnapshot] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        } catch CocoaError.fileReadNoSuchFile { return [] }
        return try urls.map { try JSONDecoder().decode(MeetingMinutesKnowledgeSnapshot.self,
            from: Data(contentsOf: $0)) }.sorted {
                if $0.generatedAt != $1.generatedAt { return $0.generatedAt < $1.generatedAt }
                return $0.outputRevision < $1.outputRevision
            }
    }

    /// Recover the save-before-enqueue gap without enrolling historical files.
    /// The caller supplies its normal meeting enumeration off the UI thread.
    func reconcile(store: MeetingStore, records: [MeetingRecord]) throws {
        for record in records {
            let url = store.directory(for: record.id).appendingPathComponent("minutes-accepted.json")
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch CocoaError.fileReadNoSuchFile { continue }
            do { try enqueue(acceptedData: data, record: record) }
            catch MeetingMinutesKnowledgeSnapshot.SnapshotError.historicalSelectionRequired { continue }
        }
    }

    private func pendingURL(meetingID: String, outputRevision: String) -> URL {
        let binding = Data((meetingID + "\0" + outputRevision).utf8)
        let key = SHA256.hash(data: binding).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
}
