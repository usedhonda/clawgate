import CryptoKit
import Foundation

/// Immutable v1 wire identity. No receipt hash authenticates a caller: the
/// eventual registered transport must bind sourceUUID to its existing writer.
struct MeetingMinutesPublication: Codable, Equatable {
    enum Operation: String, Codable { case upsert, delete }
    enum SelectionBasis: String, Codable { case futureAccepted = "future_accepted", explicitHistory = "explicit_history_selection" }
    let schemaVersion: Int
    let operation: Operation
    let sourceUUID: String
    let meetingID: String
    let outputRevision: String
    let publicationOrdinal: Int
    let previousRevision: String?
    let selectionBasis: SelectionBasis
    let payloadSHA256: String
    let payloadBase64: String

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

struct MeetingMinutesPublicationReceipt: Codable, Equatable {
    enum Status: String, Codable { case stored, searchable, deleted, conflict, pendingGap = "pending_gap", stale }
    let schemaVersion: Int
    let sourceUUID: String
    let meetingID: String
    let publicationOrdinal: Int
    let outputRevision: String
    let payloadSHA256: String
    let status: Status
    let isCurrent: Bool

    func matches(_ publication: MeetingMinutesPublication) -> Bool {
        schemaVersion == publication.schemaVersion && sourceUUID == publication.sourceUUID &&
        meetingID == publication.meetingID && publicationOrdinal == publication.publicationOrdinal &&
        outputRevision == publication.outputRevision && payloadSHA256 == publication.payloadSHA256
    }
}
