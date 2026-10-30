import Foundation
import CryptoKit

/// Producer-owned snapshot of an accepted document, independent of the
/// consumer's storage/indexing choice. Raw speech and material bodies stay local.
struct MeetingMinutesKnowledgeSnapshot: Codable {
    struct Context: Codable, Equatable {
        let meetingID: String
        let startedAt: Double
        let endedAt: Double?
        let timeZone: String
        let calendarEventID: String?

        init(record: MeetingRecord) {
            meetingID = record.id
            startedAt = record.startedAt
            endedAt = record.endedAt
            timeZone = record.timeZone
            calendarEventID = record.calendarEventID
        }
    }

    struct Citation: Codable, Equatable {
        let id: String
        let source: String
        let sourceURL: String?
        let sourceLocator: String?
        let recallLineage: MeetingRecallTranscriptLineage?
    }

    enum SnapshotError: Error, Equatable {
        case historicalSelectionRequired
        case meetingMismatch
    }

    let context: Context
    /// The revision is over the immutable accepted-file bytes, not its input
    /// fingerprint or a consumer's re-serialization of this projection.
    let outputRevision: String
    let inputFingerprint: String
    let generatedAt: Date
    let minutes: MeetingMinutes
    let citations: [Citation]
    let unresolvedNotes: [String]
    let coverageHints: [String]
    /// Acceptance proves grounding in selected input, not complete coverage of
    /// the real meeting or an independently measured recording interval.
    let coverageBasis: String
    let contextBasis: String

    init(acceptedData: Data, record: MeetingRecord, explicitlySelected: Bool = false) throws {
        let accepted = try JSONDecoder().decode(MeetingAcceptedMinutes.self, from: acceptedData)
        if let frozen = accepted.knowledgeContext {
            guard frozen.meetingID == record.id else { throw SnapshotError.meetingMismatch }
            context = frozen
            contextBasis = "accepted_generation"
        } else {
            guard explicitlySelected else { throw SnapshotError.historicalSelectionRequired }
            context = Context(record: record)
            contextBasis = "historical_selection_current_metadata"
        }
        outputRevision = "sha256:" + SHA256.hash(data: acceptedData).map { String(format: "%02x", $0) }.joined()
        inputFingerprint = accepted.fingerprint
        generatedAt = accepted.createdAt
        minutes = accepted.minutes
        unresolvedNotes = accepted.unresolvedNotes
        coverageHints = accepted.coverageHints ?? []
        coverageBasis = "selected_input_only"

        let speechIDs = Set((minutes.evidence ?? []).flatMap(\.segmentIds))
        let materialIDs = Set((minutes.evidence ?? []).flatMap { $0.materialIds ?? [] })
        var refs = accepted.segments.filter { speechIDs.contains($0.id) }.map {
            Citation(id: $0.id, source: $0.source, sourceURL: $0.sourceURL, sourceLocator: $0.sourceLocator, recallLineage: $0.recallLineage)
        }
        for material in accepted.supplementalMaterials ?? [] {
            refs += material.sections.filter { materialIDs.contains($0.id) }.map {
                Citation(id: $0.id, source: "supplemental", sourceURL: nil, sourceLocator: $0.locator, recallLineage: nil)
            }
        }
        citations = refs
    }
}
