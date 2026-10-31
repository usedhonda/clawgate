import Foundation

/// HTTPS handoff of one journaled minutes publication to the Hub. The caller
/// keeps the entry pending until the returned receipt is durably recorded.
final class MeetingMinutesHubTransport {
    enum Failure: Error, Equatable {
        /// The Hub refused this publication; other meetings can still proceed.
        case rejected(Int)
        /// Nothing can be concluded, so the whole pass waits for a later retry.
        case unavailable
    }

    private let provision: HubProducerProvision
    private let configuration: URLSessionConfiguration

    init(provision: HubProducerProvision, configuration: URLSessionConfiguration = .ephemeral) {
        self.provision = provision
        self.configuration = configuration
    }

    func send(_ publication: MeetingMinutesPublication) async throws -> MeetingMinutesPublicationReceipt {
        let delegate = AudioHubMetadataTransport.RedirectRejectingDelegate()
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = AudioHubMetadataTransport.requestTimeout
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let body = try publication.encoded()
        guard body.count <= AudioHubMetadataTransport.maxRequestBytes else {
            throw Failure.rejected(413)
        }
        do {
            let (capabilities, capabilitiesResponse) = try await session.data(for: request("v1/capabilities", method: "GET", body: nil))
            guard !delegate.rejected, (capabilitiesResponse as? HTTPURLResponse)?.statusCode == 200,
                  provision.acceptsCapabilities(capabilities, requiring: "minutes") else { throw Failure.unavailable }

            let (data, response) = try await session.data(for: request("v1/minutes/publications", method: "POST", body: body))
            guard !delegate.rejected, let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.unavailable }
            switch status {
            case 200, 201:
                return try Self.receipt(from: data, matching: publication)
            case 400, 403, 409, 413:
                throw Failure.rejected(status)
            default:
                throw Failure.unavailable
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unavailable
        }
    }

    /// HTTP success alone is not an acknowledgement: the exact identity must echo.
    static func receipt(from data: Data, matching publication: MeetingMinutesPublication) throws -> MeetingMinutesPublicationReceipt {
        guard data.count <= AudioHubMetadataTransport.maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nested = object["minutes_receipt"],
              let encoded = try? JSONSerialization.data(withJSONObject: nested),
              let receipt = try? JSONDecoder().decode(MeetingMinutesPublicationReceipt.self, from: encoded),
              receipt.matches(publication) else { throw Failure.unavailable }
        return receipt
    }

    private func request(_ path: String, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: provision.endpoint(path), timeoutInterval: AudioHubMetadataTransport.requestTimeout)
        request.httpMethod = method
        request.setValue("Bearer \(provision.bearer_token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
