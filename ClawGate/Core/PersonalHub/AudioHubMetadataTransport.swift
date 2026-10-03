import CryptoKit
import Foundation

/// Inactive, metadata-only HTTPS handoff for an already persisted audio record.
///
/// This type never reads an original file, mutates an outbox, starts a producer
/// loop, or falls back to Gateway. The caller retains the pending record until
/// it has validated the returned acknowledgement and atomically acknowledges it.
final class AudioHubMetadataTransport {
    static let maxRequestBytes = 20 * 1024 * 1024
    static let maxResponseBytes = 64 * 1024
    static let requestTimeout: TimeInterval = 30

    enum Failure: Error, Equatable {
        case invalidRecord
        case requestTooLarge
        case responseTooLarge
        case capabilitiesRejected
        case redirectRejected
        case unexpectedStatus
        case transport
        case invalidReceipt
    }

    private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
        var rejected = false

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            rejected = true
            completionHandler(nil)
        }
    }

    private let provision: HubProducerProvision
    private let configuration: URLSessionConfiguration

    init(provision: HubProducerProvision,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.provision = provision
        self.configuration = configuration
    }

    /// Sends one immutable metadata envelope. A successful return is only a
    /// validated storage acknowledgement; this method does not dequeue it.
    func send(_ record: AudioHubOutbox.PendingRecord) async throws -> HubAudioAdmission.Acknowledgement {
        guard provision.source == "clawgate", provision.allowed_domains == ["audio"] else {
            throw Failure.invalidRecord
        }
        let envelope = try validate(record)
        let delegate = RedirectRejectingDelegate()
        let session = makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }

        do {
            let capabilitiesRequest = try makeRequest(path: "v1/capabilities", method: "GET", body: nil)
            let (capabilitiesData, capabilitiesResponse) = try await fetch(capabilitiesRequest, session: session)
            guard !delegate.rejected,
                  capabilitiesData.count <= Self.maxResponseBytes,
                  let capabilitiesHTTP = capabilitiesResponse as? HTTPURLResponse,
                  capabilitiesHTTP.statusCode == 200,
                  provision.acceptsCapabilities(capabilitiesData) else {
                throw delegate.rejected ? Failure.redirectRejected : Failure.capabilitiesRejected
            }

            let eventsRequest = try makeRequest(path: "v1/events", method: "POST", body: envelope)
            let (responseData, response) = try await fetch(eventsRequest, session: session)
            guard !delegate.rejected else { throw Failure.redirectRejected }
            guard responseData.count <= Self.maxResponseBytes else { throw Failure.responseTooLarge }
            guard let responseHTTP = response as? HTTPURLResponse,
                  responseHTTP.statusCode == 200 || responseHTTP.statusCode == 201 else { throw Failure.unexpectedStatus }
            do {
                return try HubAudioAdmission.validate(response: responseData,
                                                      externalID: record.externalID,
                                                      sha256: nil,
                                                      byteLength: 0,
                                                      pipeline: nil)
            } catch {
                throw Failure.invalidReceipt
            }
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw Failure.transport
        } catch {
            throw Failure.transport
        }
    }

    private func validate(_ record: AudioHubOutbox.PendingRecord) throws -> Data {
        guard record.original == nil,
              !record.externalID.isEmpty,
              externalIDMatchesSource(record),
              record.bodySHA256.count == 64,
              record.bodySHA256.allSatisfy({ $0.isHexDigit }),
              AudioHubMetadataTransport.sha256(record.envelope) == record.bodySHA256,
              record.envelope.count <= Self.maxRequestBytes,
              let object = try? JSONSerialization.jsonObject(with: record.envelope) as? [String: Any],
              object["source"] as? String == "clawgate",
              object["domain"] as? String == "audio",
              object["kind"] as? String == "clawgate.audio-transcript.v1",
              object["external_id"] as? String == record.externalID,
              object["payload_base64"] == nil,
              object["blob_sha256"] == nil,
              object["blob"] == nil,
              object["original"] == nil else {
            if record.envelope.count > Self.maxRequestBytes { throw Failure.requestTooLarge }
            throw Failure.invalidRecord
        }
        guard let metadata = object["metadata"] as? [String: Any],
              metadata["source_uuid"] as? String == sourceUUID(from: record.externalID),
              metadata["source_record_ref"] as? String == record.sourceRecordRef,
              metadata["revision_ref"] as? String == record.revision else {
            throw Failure.invalidRecord
        }
        return record.envelope
    }

    private func fetch(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.transport }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxResponseBytes { throw Failure.responseTooLarge }
        }
        return (data, http)
    }

    private func sourceUUID(from externalID: String) -> String? {
        let parts = externalID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, let uuid = UUID(uuidString: String(parts[3])) else { return nil }
        return uuid.uuidString.lowercased() == parts[3] ? String(parts[3]) : nil
    }

    private func externalIDMatchesSource(_ record: AudioHubOutbox.PendingRecord) -> Bool {
        let parts = record.externalID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "clawgate", parts[1] == "native", parts[2] == "v1",
              let sourceUUID = UUID(uuidString: String(parts[3])) else { return false }
        let canonical = sourceUUID.uuidString.lowercased()
        guard canonical == String(parts[3]) else { return false }
        return AudioHubOutbox.externalID(sourceUUID: canonical,
                                         sourceRecordRef: record.sourceRecordRef,
                                         revision: record.revision) == record.externalID
    }

    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        let url = provision.endpoint(path)
        guard url.scheme == "https", url.host != nil else { throw Failure.invalidRecord }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        request.setValue("Bearer \(provision.bearer_token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            guard body.count <= Self.maxRequestBytes else { throw Failure.requestTooLarge }
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }
        return request
    }

    private func makeSession(delegate: URLSessionTaskDelegate) -> URLSession {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
