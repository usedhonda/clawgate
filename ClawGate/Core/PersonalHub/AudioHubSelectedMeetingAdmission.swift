import CryptoKit
import Foundation

/// Explicit, inactive admission of selected rows from a caller-supplied meeting index.
struct AudioHubSelectedMeetingAdmission {
    struct Asset {
        let row: MeetingAudioArchive.Chunk
        let original: AudioHubOutbox.OriginalReference
    }

    enum Error: Swift.Error, Equatable {
        case invalidIndex
        case invalidSelection
        case sourceClockUnknown
        case conflict
    }

    static func isAdmitted(meetingID: String, asset: Asset, checkpoints: [AudioHubControlStore.Checkpoint]) -> Bool {
        let ref = sourceRef(meetingID: meetingID, rowID: asset.row.id)
        let revision = revision(for: asset)
        return checkpoints.contains { $0.sourceRecordRef == ref && $0.revisionRef == revision }
    }

    static func admit(meetingID: String, indexData: Data, assets: [Asset],
                      selectedIDs: Set<String>, originalsRoot: URL,
                      outbox: AudioHubOutbox, control: AudioHubControlStore) throws -> [AudioHubControlStore.Checkpoint] {
        guard validComponent(meetingID), !indexData.isEmpty,
              !assets.isEmpty, selectedIDs == Set(assets.map { $0.row.id }),
              Set(assets.map { $0.row.id }).count == assets.count else { throw Error.invalidSelection }
        guard let indexedRows = try? JSONDecoder().decode([MeetingAudioArchive.Chunk].self, from: indexData),
              Set(indexedRows.map(\.id)).count == indexedRows.count else { throw Error.invalidIndex }
        let indexedByID = Dictionary(uniqueKeysWithValues: indexedRows.map { ($0.id, $0) })
        guard assets.allSatisfy({ indexedByID[$0.row.id] == $0.row }) else { throw Error.invalidIndex }
        let indexHash = sha256(indexData)
        var checkpoints: [AudioHubControlStore.Checkpoint] = []
        for asset in assets {
            guard asset.original.byteLength > 0, validComponent(asset.row.id), validComponent(asset.row.fileName),
                  asset.original.sourceRelativePath == "meetings/\(meetingID)/audio/\(asset.row.fileName)" else {
                throw Error.invalidSelection
            }
            guard asset.row.startedAt.isFinite, asset.row.endedAt.isFinite,
                  asset.row.endedAt > asset.row.startedAt else {
                let revision = revision(for: asset)
                let ref = sourceRef(meetingID: meetingID, rowID: asset.row.id)
                _ = try control.excludeOriginal(sourceRecordRef: ref, revision: revision)
                throw Error.sourceClockUnknown
            }
            _ = try AudioHubOriginalReader(root: originalsRoot, reference: asset.original)
            let ref = sourceRef(meetingID: meetingID, rowID: asset.row.id)
            let revision = revision(for: asset)
            let checkpoint = try control.admitOriginal(sourceRecordRef: ref, revision: revision, original: asset.original, into: outbox) { sourceUUID, externalID in
                let metadata: [String: Any] = [
                    "source_uuid": sourceUUID, "source_record_ref": ref, "revision_ref": revision,
                    "raw_index_sha256": indexHash, "meeting_id": meetingID,
                    "stream": asset.row.source, "chunk_id": asset.row.id,
                    "started_at": asset.row.startedAt, "ended_at": asset.row.endedAt,
                    "selection": "explicit", "privacy_flags": NSNull(),
                    "speaker_identity_confidence": "unverified"
                ]
                return try JSONSerialization.data(withJSONObject: [
                    "source": "clawgate", "domain": "audio", "kind": "selected-meeting-original",
                    "occurred_at": iso8601(asset.row.startedAt),
                    "external_id": externalID, "blob_sha256": asset.original.sha256,
                    "metadata": metadata
                ], options: [.sortedKeys])
            }
            checkpoints.append(checkpoint)
        }
        return checkpoints
    }

    private static func sourceRef(meetingID: String, rowID: String) -> String {
        "clawgate:meeting:\(meetingID):audio:\(rowID)"
    }

    private static func revision(for asset: Asset) -> String {
        var data = Data()
        for value in [asset.row.id, asset.row.source, String(asset.row.startedAt), String(asset.row.endedAt),
                      asset.row.fileName, asset.original.sha256, String(asset.original.byteLength)] {
            var length = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: value.utf8)
        }
        return "sha256:\(sha256(data))"
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
        !value.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || CharacterSet.controlCharacters.contains($0) })
    }

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func iso8601(_ value: Double) -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: Date(timeIntervalSince1970: value))
    }
}
