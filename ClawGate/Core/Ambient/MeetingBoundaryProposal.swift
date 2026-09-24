import Foundation

/// Calendar time is an anchor, not a cut point. This intentionally abstains
/// when the retained rough transcript cannot identify a conversation.
struct MeetingBoundaryProposal {
    let start: Double?
    let end: Double?
    let evidence: String
    let ambiguous: Bool
    let record: MeetingRecord?

    static func infer(eventStart: Double, eventEnd: Double,
                      rough: [TranscriptSegment], chunks: [MeetingAudioArchive.Chunk],
                      records: [MeetingRecord]) -> Self {
        let speech = rough.compactMap { segment -> (Double, TranscriptSegment)? in
            guard let at = segment.capturedAt,
                  at >= eventStart - 3600, at <= eventEnd + 3600,
                  segment.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6 else { return nil }
            return (at, segment)
        }.sorted { $0.0 < $1.0 }
        guard !speech.isEmpty else {
            return .init(start: nil, end: nil, evidence: "発話を確認できません。録音があっても無音とは断定しません。",
                         ambiguous: false, record: nil)
        }

        var groups: [[(Double, TranscriptSegment)]] = []
        for item in speech {
            if let last = groups.last?.last, item.0 - last.0 <= 8 * 60 {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }
        // A conversation must reach the scheduled interval (possibly from an
        // early start). A call starting after a previous event ended cannot be
        // claimed by that previous event merely because it is nearby.
        let relevant = groups.filter { group in
            guard let first = group.first?.0, let last = group.last?.0 else { return false }
            return group.count >= 2 && group.reduce(0, { $0 + $1.1.text.count }) >= 20 &&
                first < eventEnd && last >= eventStart - 10 * 60
        }.sorted { left, right in
            let leftChars = left.reduce(0) { $0 + $1.1.text.count }
            let rightChars = right.reduce(0) { $0 + $1.1.text.count }
            return leftChars > rightChars
        }
        guard let chosen = relevant.first, let first = chosen.first?.0,
              let last = chosen.last?.0 else {
            return .init(start: nil, end: nil, evidence: "予定に対応する発話を確認できません。",
                         ambiguous: false, record: nil)
        }
        let matches = records.filter { record in
            let finish = record.endedAt ?? record.startedAt
            return record.source == "meet" && record.startedAt <= last + 120 && finish >= first - 120
        }.sorted { abs($0.startedAt - first) < abs($1.startedAt - first) }
        let record = matches.first
        let proposedStart = min(first - 15, record?.startedAt ?? first)
        let proposedEnd = max(last + 30, record?.endedAt ?? last)
        // If the archive is incomplete, the proposal remains visible, but
        // the UI must not describe a missing interval as silence.
        let mic = chunks.filter { $0.source == "mic" && $0.startedAt < proposedEnd && $0.endedAt > proposedStart }
        guard !mic.isEmpty else {
            return .init(start: nil, end: nil, evidence: "対応するマイク録音がありません。",
                         ambiguous: false, record: nil)
        }
        let covered = unionSeconds(mic.map { (max($0.startedAt, proposedStart), min($0.endedAt, proposedEnd)) })
        let duration = proposedEnd - proposedStart
        let gap = duration > 0 && covered / duration < 0.8
        var evidence = "保存済み発話 \(chosen.count) 件"
        if chosen.prefix(3).contains(where: { item in
            ["始め", "よろしく", "お疲れ"].contains { item.1.text.contains($0) }
        }) {
            evidence += "・開始の挨拶あり"
        }
        if chosen.suffix(3).contains(where: { item in
            ["ありがとう", "終わり", "失礼"].contains { item.1.text.contains($0) }
        }) {
            evidence += "・終了の挨拶あり"
        }
        if record != nil { evidence += "・Meetの開始終了を参照" }
        if gap { evidence += "・録音に欠落あり" }
        let competingSpeech = relevant.dropFirst().contains {
            $0.reduce(0) { $0 + $1.1.text.count } >= chosen.reduce(0) { $0 + $1.1.text.count } / 5
        }
        return .init(start: proposedStart, end: proposedEnd, evidence: evidence,
                     ambiguous: competingSpeech || matches.count > 1 || gap, record: record)
    }

    private static func unionSeconds(_ intervals: [(Double, Double)]) -> Double {
        var total = 0.0
        var through = -Double.infinity
        for (begin, end) in intervals.sorted(by: { $0.0 < $1.0 }) {
            total += max(0, end - max(begin, through))
            through = max(through, end)
        }
        return total
    }
}
