import CryptoKit
import Foundation

/// Explicit selected-original delivery only. No discovery, runtime loop,
/// deletion, retention pin or Gateway fallback is installed by this type.
final class AudioHubOriginalTransport {
    enum Failure: Error, Equatable {
        case invalidRecord, capabilitiesRejected, unexpectedStatus, responseTooLarge
        case redirectRejected, transport, invalidUploadResponse, invalidReceipt
    }

    private final class Delegate: NSObject, URLSessionTaskDelegate {
        var rejected = false
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            rejected = true; completionHandler(nil)
        }
    }

    private let provision: HubProducerProvision
    private let configuration: URLSessionConfiguration

    init(provision: HubProducerProvision, configuration: URLSessionConfiguration = .ephemeral) {
        self.provision = provision; self.configuration = configuration
    }

    @discardableResult
    func deliverOne(outbox: AudioHubOutbox, control: AudioHubControlStore, originalsRoot: URL) async throws -> Bool {
        guard let record = try outbox.pending(limit: 1).first else { return false }
        let ack = try await send(record, control: control, originalsRoot: originalsRoot)
        guard let processing = ack.processingReceipt else { throw Failure.invalidReceipt }
        let receipt = try JSONSerialization.data(withJSONObject: [
            "storage_receipt": JSONSerialization.jsonObject(with: ack.storageReceipt),
            "processing_receipt": JSONSerialization.jsonObject(with: processing)
        ], options: [.sortedKeys])
        // One atomic receipt/removal commit. An ambiguous disk failure needs
        // reopen, never deletion of the source file or an invented ACK.
        try outbox.acknowledge(externalID: record.externalID, expectedEnvelope: record.envelope, receipt: receipt)
        return true
    }

    func send(_ record: AudioHubOutbox.PendingRecord, control: AudioHubControlStore,
              originalsRoot: URL) async throws -> HubAudioAdmission.Acknowledgement {
        let original = try validate(record)
        let delegate = Delegate()
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let capData = try await fetch(path: "v1/capabilities", method: "GET", body: nil,
            session: session, delegate: delegate, accepted: [200])
        struct ProcessingCapability: Decodable {
            let processing_receipt_version: Int
            let audio_original_kinds: [String]
            let processing_pipeline: String
        }
        guard provision.acceptsCapabilities(capData),
              let cap = try? JSONDecoder().decode(ProcessingCapability.self, from: capData),
              cap.processing_receipt_version == 1,
              cap.audio_original_kinds.contains("selected-meeting-original"),
              !cap.processing_pipeline.isEmpty else {
            throw Failure.capabilitiesRejected
        }
        let pipeline = cap.processing_pipeline
        var progress = try control.startUpload(record: record, pipeline: pipeline)
        do {
            let reader = try AudioHubOriginalReader(root: originalsRoot, reference: original)
            if progress.uploadID == nil {
                let bytes = try await fetch(path: "v1/uploads", method: "POST", body: Data(),
                    session: session, delegate: delegate, accepted: [201])
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let id = object["upload_id"] as? String,
                      UUID(uuidString: id)?.uuidString.lowercased() == id else { throw Failure.invalidUploadResponse }
                progress = try control.updateUpload(externalID: record.externalID, expected: progress, uploadID: id)
            }
            guard let uploadID = progress.uploadID else { throw Failure.invalidUploadResponse }
            while progress.offset < original.byteLength {
                try Task.checkCancellation()
                let chunk = try reader.readChunk(offset: progress.offset, limit: 4 * 1024 * 1024)
                let next = progress.offset + Int64(chunk.count)
                guard !chunk.isEmpty else { throw Failure.invalidUploadResponse }
                let bytes = try await fetch(path: "v1/uploads/\(uploadID)", offset: progress.offset,
                    method: "PUT", body: chunk, session: session, delegate: delegate, accepted: [200])
                struct ChunkResponse: Decodable { let next_offset: Int64 }
                guard let response = try? JSONDecoder().decode(ChunkResponse.self, from: bytes), response.next_offset == next else {
                    throw Failure.invalidUploadResponse
                }
                progress = try control.updateUpload(externalID: record.externalID, expected: progress, offset: next)
            }
            // Revalidate source presence after the last HTTP wait. An open fd
            // must not silently extend the source's existing retention period.
            _ = try reader.readChunk(offset: 0, limit: 1)
            if !progress.finalized {
                let body = try JSONSerialization.data(withJSONObject: ["sha256": original.sha256])
                let bytes = try await fetch(path: "v1/uploads/\(uploadID)/finalize", method: "POST", body: body,
                    session: session, delegate: delegate, accepted: [200])
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      object["blob_sha256"] as? String == original.sha256 else { throw Failure.invalidUploadResponse }
                progress = try control.updateUpload(externalID: record.externalID, expected: progress, finalized: true)
            }
            _ = try reader.readChunk(offset: 0, limit: 1)
            let response = try await fetch(path: "v1/events", method: "POST", body: record.envelope,
                session: session, delegate: delegate, accepted: [200, 201])
            let ack: HubAudioAdmission.Acknowledgement
            do {
                ack = try HubAudioAdmission.validate(response: response, externalID: record.externalID,
                    sha256: original.sha256, byteLength: Int(original.byteLength), pipeline: progress.pipeline,
                    previous: progress.binding)
            } catch { throw Failure.invalidReceipt }
            _ = try control.updateUpload(externalID: record.externalID, expected: progress, binding: ack.binding)
            return ack
        } catch AudioHubOriginalReader.Error.missingOriginal {
            _ = try control.updateUpload(externalID: record.externalID, expected: progress, missing: true)
            throw AudioHubOriginalReader.Error.missingOriginal
        } catch AudioHubOriginalReader.Error.contentMismatch {
            _ = try control.updateUpload(externalID: record.externalID, expected: progress, changed: true)
            throw AudioHubOriginalReader.Error.contentMismatch
        } catch AudioHubOriginalReader.Error.sourceChanged {
            _ = try control.updateUpload(externalID: record.externalID, expected: progress, changed: true)
            throw AudioHubOriginalReader.Error.sourceChanged
        }
    }

    private func validate(_ record: AudioHubOutbox.PendingRecord) throws -> AudioHubOutbox.OriginalReference {
        guard provision.source == "clawgate", provision.allowed_domains == ["audio"],
              let original = record.original, original.byteLength > 0, original.byteLength <= Int64(Int.max),
              record.envelope.count <= 20 * 1024 * 1024,
              SHA256.hash(data: record.envelope).map({ String(format: "%02x", $0) }).joined() == record.bodySHA256,
              let object = try? JSONSerialization.jsonObject(with: record.envelope) as? [String: Any],
              object["source"] as? String == "clawgate", object["domain"] as? String == "audio",
              object["kind"] as? String == "selected-meeting-original",
              object["external_id"] as? String == record.externalID,
              object["blob_sha256"] as? String == original.sha256, object["payload_base64"] == nil,
              let metadata = object["metadata"] as? [String: Any],
              let uuid = metadata["source_uuid"] as? String,
              UUID(uuidString: uuid)?.uuidString.lowercased() == uuid,
              metadata["source_record_ref"] as? String == record.sourceRecordRef,
              metadata["revision_ref"] as? String == record.revision,
              AudioHubOutbox.externalID(sourceUUID: uuid, sourceRecordRef: record.sourceRecordRef,
                                       revision: record.revision) == record.externalID else { throw Failure.invalidRecord }
        return original
    }

    private func fetch(path: String, offset: Int64? = nil, method: String, body: Data?,
                       session: URLSession, delegate: Delegate, accepted: Set<Int>) async throws -> Data {
        var components = URLComponents(url: provision.endpoint(path), resolvingAgainstBaseURL: false)!
        if let offset { components.queryItems = [.init(name: "offset", value: String(offset))] }
        guard let url = components.url, url.scheme == "https" else { throw Failure.invalidRecord }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(provision.bearer_token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
            request.setValue(method == "PUT" ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard !delegate.rejected else { throw Failure.redirectRejected }
            guard let http = response as? HTTPURLResponse, accepted.contains(http.statusCode) else { throw Failure.unexpectedStatus }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 65536 { throw Failure.responseTooLarge }
            }
            return data
        } catch let failure as Failure { throw failure }
        catch { throw Failure.transport }
    }
}
