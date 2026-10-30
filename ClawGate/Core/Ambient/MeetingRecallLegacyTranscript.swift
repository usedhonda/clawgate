import Foundation

/// Selected legacy transcript projection produced by the canonical fresh,
/// policy-filtered reader after complete pagination. Not a raw Hub event/API
/// authorization and not a Hub-STT result with invented processing lineage.
struct MeetingRecallLegacyTranscript {
    enum ImportError: Error, Equatable { case invalidProjection, bodyUnavailable, selectionMismatch, noSpeech }
    let eventID: String
    let externalID: String
    let contentSHA256: String
    let segments: [MeetingTranscriptSourceSegment]
    let coverageHints: [String]

    init(authorizedProjection data: Data, selectedEventID: String) throws {
        let gate: Gate
        do { gate = try JSONDecoder().decode(Gate.self, from: data) }
        catch { throw ImportError.invalidProjection }
        guard !gate.bodySuppressed else { throw ImportError.bodyUnavailable }
        guard gate.status == "ok" else { throw ImportError.invalidProjection }
        let projection: Projection
        do { projection = try JSONDecoder().decode(Projection.self, from: data) }
        catch { throw ImportError.invalidProjection }
        guard projection.source == "recall", ["transcript", "transcript_variant"].contains(projection.kind),
              UUID(uuidString: projection.ids.eventID) != nil,
              projection.contentHashScheme == "hub-event-v1",
              projection.contentSHA256.utf8.count == 64,
              projection.contentSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ImportError.invalidProjection
        }
        guard projection.ids.eventID == selectedEventID else { throw ImportError.selectionMismatch }
        guard ["clear", "unknown"].contains(projection.privacy.status),
              let text = projection.result.text else { throw ImportError.bodyUnavailable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.noSpeech }
        eventID = projection.ids.eventID
        externalID = projection.ids.externalID
        contentSHA256 = projection.contentSHA256
        segments = [.init(id: "recall-\(eventID)-text", source: "recall", text: text,
            sourceLocator: "Recall \(projection.kind), Hub event \(eventID), hub-event-v1:\(contentSHA256)")]
        // One untimed source-text block: no ASR result identity, speaker or
        // sample/capture bounds can be inferred from this legacy artifact.
        var hints = ["Recallの選択文字起こしに基づく記録です。元音声の発言時刻・話者・会議全体の網羅性は未確認です。"]
        if projection.privacy.status == "unknown" { hints.append("元データのプライバシー区分は未確認です。現在の読取方針で許可された本文だけを使用しています。") }
        coverageHints = hints
    }

    private struct Gate: Decodable { let status: String; let bodySuppressed: Bool }
    private struct Projection: Decodable {
        let source: String, kind: String, contentHashScheme: String
        let contentSHA256: String
        let ids: IDs
        let privacy: Privacy
        let result: Result
        private enum CodingKeys: String, CodingKey {
            case source, kind, contentHashScheme, ids, privacy, result, contentSHA256 = "contentSha256"
        }
        struct IDs: Decodable {
            let eventID: String, externalID: String
            private enum CodingKeys: String, CodingKey { case eventID = "event_id", externalID = "external_id" }
        }
        struct Privacy: Decodable { let status: String }
        struct Result: Decodable { let text: String? }
    }
}
