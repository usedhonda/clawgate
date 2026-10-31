import Foundation

/// Gives the Hub the same minutes this app shows: `MeetingStore.loadMinutes`
/// prefers the accepted file and falls back to the older export. Delivery state
/// is its own ledger, so the separate Gateway route and its policy are untouched.
actor MeetingMinutesHubPublisher {
    typealias Sender = (MeetingMinutesPublication) async throws -> MeetingMinutesPublicationReceipt
    static let shared = MeetingMinutesHubPublisher(store: MeetingStore(), sender: {
        guard let provision = try HubProducerProvision.load(source: "clawgate") else {
            throw MeetingMinutesHubTransport.Failure.unavailable
        }
        return try await MeetingMinutesHubTransport(provision: provision).send($0)
    })
    static let retryInterval: UInt64 = 300_000_000_000
    static let maxMetadataBytes = 16 * 1024 * 1024

    private let store: MeetingStore
    private let sender: Sender
    private var loop: Task<Void, Never>?
    private var syncing = false
    private var syncAgain = false

    init(store: MeetingStore, sender: @escaping Sender) {
        self.store = store; self.sender = sender
    }

    /// Hosts without a Hub provision stage nothing and send nothing.
    func start() {
        guard loop == nil, (try? HubProducerProvision.load(source: "clawgate")) != nil else { return }
        loop = Task {
            while !Task.isCancelled {
                await sync()
                try? await Task.sleep(nanoseconds: Self.retryInterval)
            }
        }
    }

    /// A second caller arriving mid-send must not post the same entry again.
    func sync() async {
        if syncing { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            await syncOnce()
        } while syncAgain
    }

    private func syncOnce() async {
        let ledger: MeetingMinutesKnowledgeOutbox
        do {
            let primary = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: Self.maxMetadataBytes)
            ledger = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: Self.maxMetadataBytes,
                directoryName: "knowledge-outbox-hub", sourceUUID: primary.sourceUUID, compactsWhenStored: true)
        } catch {
            NSLog("[MinutesHub] ledger unavailable")
            return
        }
        // Staging then sending per record compacts bodies as it goes, so a large
        // backlog stays inside the ledger's metadata quota.
        for record in store.all() where record.mergedIntoMeetingID == nil {
            stage(record, in: ledger)
            guard await drain(ledger) else { return }
        }
        _ = await drain(ledger)
    }

    private func stage(_ record: MeetingRecord, in ledger: MeetingMinutesKnowledgeOutbox) {
        let directory = store.directory(for: record.id)
        do {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("minutes-accepted.json")),
               let accepted = try? JSONDecoder().decode(MeetingAcceptedMinutes.self, from: data) {
                try ledger.enqueue(acceptedData: data, record: record, explicitlySelected: accepted.knowledgeContext == nil)
            } else if let data = try? Data(contentsOf: directory.appendingPathComponent("minutes.json")) {
                try ledger.enqueue(exportedData: data, record: record)
            }
        } catch {
            NSLog("[MinutesHub] staging skipped one record")
        }
    }

    /// Returns false when the Hub cannot be reached; pending entries stay journaled.
    private func drain(_ ledger: MeetingMinutesKnowledgeOutbox) async -> Bool {
        var refused = Set<String>()
        do {
            for publication in try ledger.publications() where !refused.contains(publication.meetingID) {
                do {
                    let receipt = try await sender(publication)
                    try ledger.receive(receipt, expected: publication)
                    NSLog("[MinutesHub] receipt=%@ current=%d", receipt.status.rawValue, receipt.isCurrent)
                } catch MeetingMinutesHubTransport.Failure.rejected(let status) {
                    // Later revisions of this meeting wait so ordinals stay ordered.
                    refused.insert(publication.meetingID)
                    NSLog("[MinutesHub] rejected status=%d; pending retained", status)
                }
            }
            return true
        } catch {
            NSLog("[MinutesHub] delivery unresolved; pending retained")
            return false
        }
    }
}
