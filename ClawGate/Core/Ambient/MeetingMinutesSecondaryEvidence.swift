import Foundation
import CryptoKit

/// Generated minutes are evidence of what a document says, not a recording.
/// Uses the existing citation wire fields so older consumers can retain it.
enum MeetingMinutesSecondaryEvidence {
    static let source = "existing-minutes"
    static let label = "【既存議事録・原音未確認】"

    static func segments(_ notes: [MeetingGoogleMaterials.GeneratedNote]) -> [MeetingTranscriptSourceSegment] {
        notes.flatMap { segments(text: $0.text, id: $0.id, sourceURL: $0.sourceURL, locator: $0.locator) }
    }

    static func segments(text: String, id: String, sourceURL: String?, locator: String?) -> [MeetingTranscriptSourceSegment] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        var result: [MeetingTranscriptSourceSegment] = []
        var start = text.startIndex
        var offset = 0
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 6_000, limitedBy: text.endIndex) ?? text.endIndex
            let slice = String(text[start..<end])
            result.append(MeetingTranscriptSourceSegment(id: "minutes-note-\(id)-\(offset)",
                source: source, text: slice, sourceURL: sourceURL,
                sourceLocator: "\(locator ?? "document") · sha256:\(digest) · characters \(offset)..<\(offset + slice.count) · 原音未確認"))
            offset += slice.count; start = end
        }
        return result
    }

    /// Citation validation runs first. This adds provenance display metadata,
    /// never inferred speech or new evidence, when a model omits the label.
    static func annotate(_ minutes: MeetingMinutes, segments: [MeetingMinutesSegment])
        -> (minutes: MeetingMinutes, claims: [String: String]) {
        let secondaryIDs = Set(segments.filter { $0.source == source }.map(\.id))
        var changes: [String: String] = [:]
        for item in minutes.evidence ?? [] where !item.claim.isEmpty && !item.claim.hasPrefix(label) {
            if !secondaryIDs.isDisjoint(with: item.segmentIds) {
                changes[item.claim] = label + item.claim
            }
        }
        guard !changes.isEmpty else { return (minutes, changes) }
        func marked(_ claim: String) -> String { changes[claim] ?? claim }
        let summary = MeetingMinutesParser.summarySentences(minutes.summary)
        let summaryChanged = summary.contains { changes[$0] != nil }
        return (MeetingMinutes(title: minutes.title,
            summary: summaryChanged ? summary.map(marked).joined(separator: "\n") : minutes.summary,
            topics: minutes.topics.map { .init(heading: $0.heading, points: $0.points.map(marked)) },
            decisions: minutes.decisions.map(marked),
            actionItems: minutes.actionItems.map { .init(what: marked($0.what), owner: $0.owner, due: $0.due, mine: $0.mine) },
            openQuestions: minutes.openQuestions.map(marked),
            evidence: minutes.evidence?.map { .init(claim: marked($0.claim), segmentIds: $0.segmentIds, materialIds: $0.materialIds) },
            attendance: minutes.attendance, language: minutes.language), changes)
    }

    static func validate(_ minutes: MeetingMinutes, segments: [MeetingMinutesSegment]) throws {
        let secondaryIDs = Set(segments.filter { $0.source == source }.map(\.id))
        guard !secondaryIDs.isEmpty else { return }
        let claims = MeetingMinutesParser.summarySentences(minutes.summary)
            + minutes.topics.flatMap(\.points) + minutes.decisions
            + minutes.actionItems.map(\.what) + minutes.openQuestions
        for claim in claims {
            let references = (minutes.evidence ?? []).filter { $0.claim == claim }.flatMap(\.segmentIds)
            if !secondaryIDs.isDisjoint(with: references), !claim.hasPrefix(label) {
                throw MeetingMinutesError.invalidEvidence(claim: claim,
                    reason: "既存議事録に基づく情報には原音未確認の表示が必要です")
            }
        }
    }
}
