import Foundation

/// One explicitly requested metadata delivery. Constructing this helper does
/// not start a producer loop; callers invoke `deliverOne()` themselves.
struct AudioHubTranscriptDelivery {
    typealias Sender = (AudioHubOutbox.PendingRecord) async throws -> HubAudioAdmission.Acknowledgement

    enum Error: Swift.Error, Equatable {
        case invalidReceipt
    }

    private let outbox: AudioHubOutbox
    private let send: Sender

    init(outbox: AudioHubOutbox, send: @escaping Sender) {
        self.outbox = outbox
        self.send = send
    }

    init(outbox: AudioHubOutbox, transport: AudioHubMetadataTransport) {
        self.init(outbox: outbox) { record in
            try await transport.send(record)
        }
    }

    /// Delivers and durably dequeues exactly the first pending record.
    /// Transport/network/receipt failures leave the immutable pending record
    /// untouched. An ambiguous local commit failure requires reopening the
    /// outbox to determine whether the receipt/removal already committed.
    @discardableResult
    func deliverOne() async throws -> AudioHubOutbox.PendingRecord? {
        guard let record = try outbox.pending(limit: 1).first else { return nil }
        guard record.original == nil else { throw Error.invalidReceipt }
        let acknowledgement = try await send(record)
        guard acknowledgement.processingReceipt == nil,
              acknowledgement.binding.jobID == nil,
              acknowledgement.binding.pipelineVersion == nil else {
            throw Error.invalidReceipt
        }
        let response: Data
        do {
            response = try JSONSerialization.data(withJSONObject: [
                "storage_receipt": try JSONSerialization.jsonObject(with: acknowledgement.storageReceipt)
            ])
        } catch {
            throw Error.invalidReceipt
        }
        do {
            let validated = try HubAudioAdmission.validate(response: response,
                                                           externalID: record.externalID,
                                                           sha256: nil,
                                                           byteLength: 0,
                                                           pipeline: nil)
            guard validated.binding.eventID == acknowledgement.binding.eventID else {
                throw Error.invalidReceipt
            }
        } catch {
            throw Error.invalidReceipt
        }
        try outbox.acknowledge(externalID: record.externalID,
                              expectedEnvelope: record.envelope,
                              receipt: acknowledgement.storageReceipt)
        return record
    }
}
