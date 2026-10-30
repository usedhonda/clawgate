import Foundation

/// The owner-frozen read bridge, not a generic Hub tool or an access grant.
enum MeetingRecallReadBridge {
    enum Failure: Error { case unavailable, denied, invalidResponse, changed, selectionRequired, noText, tooLarge }
    enum Kind: String, Codable, CaseIterable {
        case original = "recall.audio-original.v1", transcript, variant = "transcript_variant"
        var label: String {
            switch self { case .original: return "録音原本"; case .transcript: return "文字起こし"; case .variant: return "別版の文字起こし" }
        }
    }
    struct Candidate: Decodable, Identifiable {
        let id: String
        let source: String, domain: String, kind: Kind
        let occurred_at: String, received_at: String
        let blob_sha256: String?
        let ingest_sequence: Int
    }
    struct CandidatesRequest: Encodable {
        let schemaVersion = 1
        let sourceUUID: String
        let kind: Kind
        let start: String?, end: String?, cursor: String?
        let limit = 30
    }
    struct Candidates: Decodable {
        let schemaVersion: Int, status: String, errorCode: String?
        let items: [Candidate], nextCursor: String?, complete: Bool
        let timeBasis: String, coverageBasis: String
    }
    struct Binding: Codable, Equatable {
        let eventId: String, source: String, externalId: String, kind: String
        let resultId: String?, processingVersion: String?
        let contentHashScheme: String, contentSha256: String
        let parents: [MeetingRecallTranscriptLineage.Parent]
        let privacy: String, metadataOnly: Bool
    }
    struct ResolveRequest: Encodable {
        let schemaVersion = 1
        let sourceUUID: String, originalEventId: String
    }
    struct ResolvedResult: Decodable, Identifiable {
        let binding: Binding
        let parentVerified: Bool, multiOriginal: Bool
        var id: String { binding.eventId }
    }
    struct Resolution: Decodable {
        let schemaVersion: Int, status: String, errorCode: String?
        let originalBinding: Binding?
        let results: [ResolvedResult]
        let relatedTruncated: Bool, complete: Bool, unverifiedCount: Int
        let autoSelectableEventId: String?

        func chosen(originalID: String, explicitResultID: String?) throws -> (Binding, Binding, String) {
            guard schemaVersion == 1, ["ok", "incomplete", "selection_required"].contains(status),
                  let original = originalBinding, original.eventId == originalID,
                  original.source == "recall", original.kind == Kind.original.rawValue else { throw Failure.denied }
            guard let resultID = explicitResultID ?? autoSelectableEventId,
                  let result = results.first(where: { $0.id == resultID }), result.parentVerified else {
                throw Failure.selectionRequired
            }
            let parent = MeetingRecallTranscriptLineage.Parent(source: original.source,
                externalID: original.externalId, eventID: original.eventId)
            guard result.binding.parents.contains(parent) else { throw Failure.invalidResponse }
            if explicitResultID == nil {
                guard complete, !relatedTruncated, unverifiedCount == 0, results.count == 1,
                      !result.multiOriginal, result.binding.parents == [parent] else { throw Failure.selectionRequired }
            }
            return (original, result.binding, explicitResultID == nil ? "original_single" : "explicit_result")
        }
    }
    struct ReadRequest: Encodable {
        let schemaVersion = 1
        let sourceUUID: String, eventId: String, selectionBasis: String
        let originalBinding: Binding?, expectedBinding: Binding?
        let offset: Int
    }
    struct Projection: Decodable {
        let status: String, kind: String, source: String
        let ids: IDs, privacy: Privacy, processingVersion: String?
        let result: Result, bodySuppressed: Bool
        let contentSha256: String, contentHashScheme: String
        struct IDs: Decodable {
            let event_id: String, external_id: String, result_id: String?
            let parent_refs: [MeetingRecallTranscriptLineage.Parent]
        }
        struct Privacy: Decodable { let status: String }
        struct Result: Decodable { let status: String?, text: String? }
    }
    struct Page: Decodable {
        let offset: Int, nextOffset: Int?, complete: Bool, unit: String
    }
    struct Read: Decodable {
        let schemaVersion: Int, status: String, errorCode: String?
        let projection: Projection?, binding: Binding?, originalBinding: Binding?, page: Page?
    }

    /// Completes every page under the same freshly observed binding. No partial
    /// transcript escapes on denial, revision change, timeout or a size limit.
    static func readSelection(items: [MeetingRecallSelectionStore.Item], selectionFingerprint: String,
                              sourceUUID: String,
                              resolve: (ResolveRequest) async throws -> Resolution,
                              read: (ReadRequest) async throws -> Read) async throws -> MeetingMinutesPreparation.RecallInput {
        var segments: [MeetingTranscriptSourceSegment] = []
        var hints = ["Recallの明示選択に基づく記録です。発言時刻・話者・会議全体の網羅性は未確認です。"]
        var total = 0
        var artifacts = Set<String>()
        for item in items {
            let initialCount = segments.count
            try Task.checkCancellation()
            guard let kind = item.kind.flatMap(Kind.init(rawValue:)) else { throw Failure.selectionRequired }
            let original: Binding?, basis: String, eventID: String
            var expected: Binding?
            if kind == .original {
                let resolution = try await resolve(.init(sourceUUID: sourceUUID, originalEventId: item.eventID))
                let chosen = try resolution.chosen(originalID: item.eventID, explicitResultID: item.resultEventID)
                original = chosen.0; expected = chosen.1; eventID = chosen.1.eventId; basis = chosen.2
            } else {
                guard item.resultEventID == nil else { throw Failure.invalidResponse }
                original = nil; expected = nil; eventID = item.eventID; basis = "legacy_direct"
            }
            guard artifacts.insert(eventID).inserted else { throw Failure.selectionRequired }
            var offset = 0
            while true {
                try Task.checkCancellation()
                let response = try await read(.init(sourceUUID: sourceUUID, eventId: eventID,
                    selectionBasis: basis, originalBinding: original, expectedBinding: expected, offset: offset))
                guard response.schemaVersion == 1, ["ok", "incomplete"].contains(response.status),
                      let binding = response.binding, let projection = response.projection, let page = response.page else {
                    throw Failure.denied
                }
                guard binding.eventId == eventID, expected == nil || expected == binding,
                      response.originalBinding == original,
                      original != nil || binding.kind == kind.rawValue else { throw Failure.changed }
                guard binding.contentHashScheme == "hub-event-v1", binding.contentSha256.count == 64,
                      binding.contentSha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      !binding.metadataOnly, ["clear", "unknown"].contains(binding.privacy),
                      projection.status == "ok", !projection.bodySuppressed,
                      projection.source == binding.source, projection.kind == binding.kind,
                      projection.ids.event_id == binding.eventId, projection.ids.external_id == binding.externalId,
                      projection.ids.result_id == binding.resultId, projection.ids.parent_refs == binding.parents,
                      projection.processingVersion == binding.processingVersion,
                      projection.privacy.status == binding.privacy,
                      projection.contentSha256 == binding.contentSha256,
                      projection.contentHashScheme == binding.contentHashScheme,
                      let text = projection.result.text,
                      page.offset == offset, page.unit == "unicode_codepoint" else { throw Failure.invalidResponse }
                let count = text.unicodeScalars.count
                guard count <= 2000, count > 0 || page.complete else { throw Failure.invalidResponse }
                total += count
                guard total <= 200_000 else { throw Failure.tooLarge }
                var lineage: MeetingRecallTranscriptLineage?
                if binding.source == "hub-stt" {
                    guard binding.kind == "voicelog.audio-transcript.v1", let resultID = binding.resultId,
                          UUID(uuidString: resultID) != nil, let version = binding.processingVersion, !version.isEmpty,
                          !binding.parents.isEmpty, binding.parents.allSatisfy({ $0.source == "recall" }),
                          ["complete", "partial"].contains(projection.result.status ?? "") else { throw Failure.invalidResponse }
                    lineage = .init(eventID: binding.eventId, resultID: resultID, processingVersion: version,
                        parents: binding.parents, segmentIndex: nil)
                    if projection.result.status == "partial" { hints.append("選択した文字起こしは部分的な結果です。") }
                } else {
                    guard binding.source == "recall", [Kind.transcript.rawValue, Kind.variant.rawValue].contains(binding.kind) else {
                        throw Failure.invalidResponse
                    }
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.init(id: "recall-\(eventID)-text-\(offset)", source: "recall", text: text,
                        sourceLocator: "Hub event \(eventID), hub-event-v1:\(binding.contentSha256), text codepoints \(offset)..<\(offset + count)",
                        recallLineage: lineage))
                }
                if binding.privacy == "unknown" { hints.append("元データのプライバシー区分は未確認です。現在の読取方針で許可された本文だけを使用しています。") }
                expected = binding
                if page.complete {
                    guard page.nextOffset == nil else { throw Failure.invalidResponse }
                    break
                }
                guard let next = page.nextOffset, next == offset + count, next > offset else { throw Failure.invalidResponse }
                offset = next
            }
            guard segments.count > initialCount else { throw Failure.noText }
        }
        guard !segments.isEmpty else { throw Failure.noText }
        var seen = Set<String>()
        return .init(selectionFingerprint: selectionFingerprint, segments: segments,
            coverageHints: hints.filter { seen.insert($0).inserted })
    }
}
