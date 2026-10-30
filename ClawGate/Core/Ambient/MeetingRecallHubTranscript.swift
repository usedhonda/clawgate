import Foundation

/// Adapts the existing OpenClaw policy-filtered Hub-STT projection, not a raw
/// Hub event. The caller must obtain it through its authenticated reader after
/// explicit selection; this type does not grant access or choose a recording.
struct MeetingRecallHubTranscript {
    typealias Parent = MeetingRecallTranscriptLineage.Parent

    enum ImportError: Error, Equatable {
        case invalidProjection, selectionMismatch, bodyUnavailable, unverifiedParents, noSpeech
    }

    let eventID: String
    let resultID: String
    let processingVersion: String
    let parents: [Parent]
    let segments: [MeetingTranscriptSourceSegment]
    let speakerLabels: [String?]
    let coverageHints: [String]

    init(authorizedProjection data: Data, selectedEventID: String, selectedResultID: String) throws {
        let gate: ReadGate
        do { gate = try JSONDecoder().decode(ReadGate.self, from: data) }
        catch { throw ImportError.invalidProjection }
        guard !gate.bodySuppressed else { throw ImportError.bodyUnavailable }
        guard gate.status == "ok" else { throw ImportError.invalidProjection }
        let projection: Projection
        do { projection = try JSONDecoder().decode(Projection.self, from: data) }
        catch { throw ImportError.invalidProjection }
        guard projection.source == "hub-stt",
              projection.kind == "voicelog.audio-transcript.v1", projection.errors.isEmpty,
              UUID(uuidString: projection.ids.eventID) != nil,
              UUID(uuidString: projection.ids.resultID) != nil,
              !projection.processingVersion.isEmpty else { throw ImportError.invalidProjection }
        guard projection.ids.eventID == selectedEventID,
              projection.ids.resultID == selectedResultID else { throw ImportError.selectionMismatch }
        guard ["clear", "unknown"].contains(projection.privacy.status),
              projection.result.text != nil else { throw ImportError.bodyUnavailable }
        guard !projection.ids.parents.isEmpty, projection.ids.parents.allSatisfy({
            $0.source == "recall" && !$0.externalID.isEmpty && UUID(uuidString: $0.eventID) != nil
        }) else { throw ImportError.unverifiedParents }
        guard ["complete", "partial"].contains(projection.result.status),
              !projection.result.segments.isEmpty else { throw ImportError.noSpeech }
        guard ["known", "partial", "unknown"].contains(projection.capture.status) else {
            throw ImportError.invalidProjection
        }

        var speech: [MeetingTranscriptSourceSegment] = []
        var labels: [String?] = []
        for (index, segment) in projection.result.segments.enumerated() {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                  segment.end >= segment.start else { throw ImportError.invalidProjection }
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            speech.append(MeetingTranscriptSourceSegment(
                id: "recall-\(selectedEventID)-\(index)", source: "recall", text: segment.text,
                sourceLocator: "Hub result \(selectedEventID), segment \(index)",
                startSeconds: segment.start, endSeconds: segment.end,
                recallLineage: MeetingRecallTranscriptLineage(eventID: projection.ids.eventID,
                    resultID: projection.ids.resultID, processingVersion: projection.processingVersion,
                    parents: projection.ids.parents, segmentIndex: index)))
            // A local diarization label is not a named person's identity.
            labels.append(segment.speakerLabel)
        }
        guard !speech.isEmpty else { throw ImportError.noSpeech }
        eventID = projection.ids.eventID; resultID = projection.ids.resultID
        processingVersion = projection.processingVersion; parents = projection.ids.parents
        segments = speech; speakerLabels = labels
        var hints = ["Recallの選択音声に基づく記録です。会議全体の網羅性は未確認です。"]
        if projection.capture.status != "known" { hints.append("元音声の実録音時刻には未確認の範囲があります。") }
        if projection.result.status == "partial" { hints.append("選択した文字起こしは部分的な結果です。") }
        coverageHints = hints
    }

    private struct ReadGate: Decodable { let status: String; let bodySuppressed: Bool }

    private struct Projection: Decodable {
        let source: String, kind: String, processingVersion: String
        let errors: [String]
        let ids: IDs
        let privacy: Privacy
        let result: Result
        let capture: Capture
        struct IDs: Decodable {
            let eventID: String, resultID: String
            let parents: [Parent]
            private enum CodingKeys: String, CodingKey {
                case eventID = "event_id", resultID = "result_id", parents = "parent_refs"
            }
        }
        struct Privacy: Decodable { let status: String }
        struct Capture: Decodable { let status: String }
        struct Result: Decodable {
            let status: String
            let text: String?
            let segments: [Segment]
        }
        struct Segment: Decodable {
            let start: Double, end: Double
            let text: String
            let speakerLabel: String?
            private enum CodingKeys: String, CodingKey {
                case start = "start_sec", end = "end_sec", text, speakerLabel = "speaker_label"
            }
        }
    }
}
