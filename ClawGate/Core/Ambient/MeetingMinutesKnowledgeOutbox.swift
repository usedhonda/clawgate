import Foundation

/// Local producer staging only. Enqueuing is not consumer storage or indexing.
/// The accepted document remains authoritative if staging fails or is interrupted.
struct MeetingMinutesKnowledgeOutbox {
    let directory: URL
    private let storage: AudioHubOutbox

    /// Reuse the existing bounded, synchronized metadata journal. There is no
    /// implicit production quota or second implementation of its crash/CAS rules.
    init(store: MeetingStore, maxMetadataBytes: Int) throws {
        directory = store.root.appendingPathComponent("knowledge-outbox", isDirectory: true)
        storage = try AudioHubOutbox(directory: directory, maxMetadataBytes: maxMetadataBytes)
    }

    @discardableResult
    func enqueue(acceptedData: Data, record: MeetingRecord,
                 explicitlySelected: Bool = false) throws -> MeetingMinutesKnowledgeSnapshot {
        let snapshot = try MeetingMinutesKnowledgeSnapshot(acceptedData: acceptedData,
            record: record, explicitlySelected: explicitlySelected)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(snapshot)
        try storage.enqueue(sourceRecordRef: "meeting-minutes:" + snapshot.context.meetingID,
            revision: snapshot.outputRevision) { _, _ in payload }
        return snapshot
    }

    func pending() throws -> [MeetingMinutesKnowledgeSnapshot] {
        return try storage.pending(limit: Int.max).map {
            try JSONDecoder().decode(MeetingMinutesKnowledgeSnapshot.self, from: $0.envelope)
        }.sorted {
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
}
