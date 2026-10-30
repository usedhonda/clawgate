import Darwin
import Foundation

/// A fixed body-free observation, never a cached permission or delivery receipt.
struct MeetingMinutesPublicationAdmission: Codable {
    enum Outcome: String, Codable {
        case attempted, confirmedDocumentRejection, methodUnavailable
        case sourceUnbound, callerUnavailable, unexpectedAcceptance, unknownFailure
    }
    let schemaVersion: Int
    let sourceUUID: String
    let outcome: Outcome

    static func classify(_ error: Error) -> Outcome {
        guard case OpenClawError.serverError(let code, let message) = error else { return .unknownFailure }
        // Match fixed literals only. Never persist an error message, credential,
        // response body or a hash/prefix of one.
        if code == "MINUTES_DOCUMENT_INVALID" || message == "MINUTES_DOCUMENT_INVALID" {
            return .confirmedDocumentRejection
        }
        if code == "MINUTES_SOURCE_UNBOUND" || message == "MINUTES_SOURCE_UNBOUND" { return .sourceUnbound }
        if code == "MINUTES_CALLER_UNAVAILABLE" || message == "MINUTES_CALLER_UNAVAILABLE" { return .callerUnavailable }
        return .unknownFailure
    }

    static func runIfAvailable(store: MeetingStore, client: OpenClawWSClient) async {
        guard await client.supportsMinutesPublication() else { return }
        do {
            let ledger = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 16 * 1024 * 1024)
            let url = ledger.directory.appendingPathComponent("publication-admission.json")
            // Any previous attempt, including uncertain outcome, suppresses an
            // automatic retry. Do not turn reconnect into a probe loop.
            let marker = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
            if marker < 0 {
                if errno == EEXIST { return }
                throw AudioHubOutbox.Error.ioFailure
            }
            close(marker)
            _ = try AudioHubOutbox.persist(Self(schemaVersion: 1, sourceUUID: ledger.sourceUUID,
                outcome: .attempted), to: url, maxBytes: 4096)
            let outcome = await client.checkMinutesPublicationAdmission(sourceUUID: ledger.sourceUUID)
            _ = try AudioHubOutbox.persist(Self(schemaVersion: 1, sourceUUID: ledger.sourceUUID,
                outcome: outcome), to: url, maxBytes: 4096)
            NSLog("[MinutesPublication] admission observation=%@; not a publication receipt", outcome.rawValue)
        } catch {
            NSLog("[MinutesPublication] admission observation unavailable")
        }
    }
}
