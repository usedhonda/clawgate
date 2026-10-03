import Foundation

/// Audio admission is storage plus durable processing intent, not completed STT.
/// Not connected to a live producer until its capacity/checkpoint is agreed.
enum HubAudioAdmission {
    struct Binding: Codable, Equatable {
        let eventID: String
        let jobID: String?
        let pipelineVersion: String?
    }

    struct Acknowledgement {
        let storageReceipt: Data
        let processingReceipt: Data?
        let binding: Binding
    }

    private struct Processing: Decodable {
        let receipt_version: Int
        let intent_committed: Bool
        let job_id: String
        let original_event_id: String
        let pipeline_version: String
        let state: String
    }

    static func validate(response: Data, externalID: String, sha256: String?, byteLength: Int,
                         pipeline: String?, previous: Binding? = nil) throws -> Acknowledgement {
        guard response.count <= 65536, !externalID.isEmpty, byteLength >= 0,
              let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let storage = object["storage_receipt"] as? [String: Any],
              Set(storage.keys) == Set(["receipt_version", "source", "external_id", "event_id", "sha256", "byte_length", "ingest_sequence"]) else {
            throw HubProducerProvision.Failure.invalidReceipt
        }
        let storageData = try JSONSerialization.data(withJSONObject: storage, options: [.sortedKeys])
        let receipt = try JSONDecoder().decode(HubMetadataReceipt.self, from: storageData)
        guard receipt.receipt_version == 1, receipt.source == "clawgate", receipt.external_id == externalID,
              canonicalUUID(receipt.event_id), receipt.sha256 == sha256, receipt.byte_length == byteLength,
              receipt.ingest_sequence > 0, receipt.ingest_sequence <= 9_007_199_254_740_991 else {
            throw HubProducerProvision.Failure.invalidReceipt
        }
        let result: Acknowledgement
        if let sha256 {
            guard sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  byteLength > 0, let pipeline, !pipeline.isEmpty,
                  let processing = object["processing_receipt"] as? [String: Any] else {
                throw HubProducerProvision.Failure.invalidReceipt
            }
            let processingData = try JSONSerialization.data(withJSONObject: processing, options: [.sortedKeys])
            let job = try JSONDecoder().decode(Processing.self, from: processingData)
            guard job.receipt_version == 1, job.intent_committed, canonicalUUID(job.job_id),
                  job.original_event_id == receipt.event_id, job.pipeline_version == pipeline,
                  ["pending", "leased", "completed", "failed", "expired"].contains(job.state) else {
                throw HubProducerProvision.Failure.invalidReceipt
            }
            result = Acknowledgement(storageReceipt: storageData, processingReceipt: processingData,
                                     binding: Binding(eventID: receipt.event_id, jobID: job.job_id, pipelineVersion: pipeline))
        } else {
            guard byteLength == 0, storage["sha256"] is NSNull else { throw HubProducerProvision.Failure.invalidReceipt }
            result = Acknowledgement(storageReceipt: storageData, processingReceipt: nil,
                                     binding: Binding(eventID: receipt.event_id, jobID: nil, pipelineVersion: nil))
        }
        guard previous == nil || previous == result.binding else { throw HubProducerProvision.Failure.invalidReceipt }
        return result
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}
