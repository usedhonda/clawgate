import Foundation

/// Freeze the accepted version the owner actually saw before sending it.
struct MeetingMinutesKnowledgeSelection {
    enum SelectionError: Error { case changed }
    let data: Data
    let historical: Bool

    init(store: MeetingStore, record: MeetingRecord, expectedRevision: String) throws {
        guard store.load(id: record.id) == record else { throw SelectionError.changed }
        let data = try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json"))
        guard "sha256:" + MeetingMinutesPublication.digest(data) == expectedRevision else { throw SelectionError.changed }
        let accepted = try JSONDecoder().decode(MeetingAcceptedMinutes.self, from: data)
        self.data = data
        historical = accepted.knowledgeContext == nil
    }
}
