import Foundation

/// The single background publisher for the installation's minutes store. No
/// model work, recording action, notification, new socket or timer is started.
actor MeetingMinutesPublisher {
    typealias Sender = (MeetingMinutesPublication) async throws -> MeetingMinutesPublicationReceipt
    static let shared = MeetingMinutesPublisher(store: MeetingStore(), maxMetadataBytes: 16 * 1024 * 1024)
    private let store: MeetingStore
    private let metadataBytes: Int
    private var sender: Sender?
    private var draining = false
    private var drainAgain = false

    init(store: MeetingStore, maxMetadataBytes: Int) {
        self.store = store; metadataBytes = maxMetadataBytes
    }

    /// Production hook only. Isolated stores/import tools are not silently
    /// enrolled into the installation's namespace by constructing a test store.
    nonisolated static func didAccept(store: MeetingStore, record: MeetingRecord, acceptedData: Data) {
        guard store.root.standardizedFileURL == MeetingStore().root.standardizedFileURL else { return }
        Task { await shared.accept(record: record, acceptedData: acceptedData) }
    }

    func accept(record: MeetingRecord, acceptedData: Data, explicitlySelected: Bool = false) async {
        do {
            let ledger = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: metadataBytes)
            try ledger.enqueue(acceptedData: acceptedData, record: record, explicitlySelected: explicitlySelected)
        } catch {
            // Never roll back an accepted document because knowledge delivery
            // failed. Reconnect recovery can reconcile its authoritative file.
            NSLog("[MinutesPublication] staging unavailable; accepted document retained")
            return
        }
        await drain()
    }

    func connect(send: @escaping Sender) async {
        sender = send
        do {
            let ledger = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: metadataBytes)
            // Legacy accepted files lack the explicit generation marker and
            // remain excluded. Recovery is never an all-history import.
            try ledger.reconcile(store: store, records: store.all())
        } catch {
            NSLog("[MinutesPublication] reconciliation incomplete; existing pending retained")
        }
        await drain()
    }

    func disconnect() { sender = nil }

    private func drain() async {
        if draining { drainAgain = true; return }
        guard sender != nil else { return }
        draining = true
        defer { draining = false }
        repeat {
            drainAgain = false
            do {
                let ledger = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: metadataBytes)
                // A progress query is the same immutable envelope. Each item
                // is attempted once per event-triggered drain, never polled.
                let publications = try ledger.publications() + ledger.awaitingSearchability()
                for publication in publications {
                    guard let send = sender else { return }
                    let receipt = try await send(publication)
                    // Reopen after the await: another acceptance can legitimately
                    // advance the journal while this request is in flight.
                    let current = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: metadataBytes)
                    try current.receive(receipt, expected: publication)
                    guard receipt.status == .stored || receipt.status == .searchable || receipt.status == .deleted else {
                        NSLog("[MinutesPublication] receipt unresolved=%@; pending retained", receipt.status.rawValue)
                        return
                    }
                    NSLog("[MinutesPublication] receipt=%@ current=%d", receipt.status.rawValue, receipt.isCurrent)
                }
            } catch {
                // An uncertain result is retried only by a later real connect
                // or acceptance event with the same journaled envelope.
                NSLog("[MinutesPublication] delivery unresolved; immutable pending retained")
                return
            }
        } while drainAgain && sender != nil
    }
}
