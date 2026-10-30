import Foundation

/// A private registration candidate, not server attestation or a permission.
/// The consumer owner must compare it with the authenticated paired device.
struct MeetingMinutesPublisherIdentity: Codable, Equatable {
    let schemaVersion: Int
    let sourceUUID: String
    let deviceId: String
    let evidence: String

    static func prepare(store: MeetingStore, existingDeviceID: String?,
                        maxMetadataBytes: Int) throws -> URL? {
        // No identity means no bootstrap, not permission to create a key.
        guard let deviceID = existingDeviceID else { return nil }
        guard deviceID.utf8.count == 64,
              deviceID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AudioHubOutbox.Error.invalidSourceRecord
        }
        let ledger = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: maxMetadataBytes)
        let candidate = Self(schemaVersion: 1, sourceUUID: ledger.sourceUUID,
            deviceId: deviceID, evidence: "existing_connected_ws_device_identity")
        let url = ledger.directory.appendingPathComponent("source-binding-candidate.json")
        _ = try AudioHubOutbox.persist(candidate, to: url, maxBytes: 4096)
        return url
    }
}
