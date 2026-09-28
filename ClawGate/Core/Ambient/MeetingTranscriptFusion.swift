import Foundation

/// Deterministic fusion of local capture and external transcript material.
/// No model is called here: source text remains evidence and every decision is
/// represented in the returned result.
struct MeetingTranscriptFusionResult: Equatable {
    let segments: [MeetingTranscriptSourceSegment]
    /// IDs folded into each retained segment by exact duplicate collapsing.
    let provenanceBySegmentID: [String: [String]]
    let unresolvedNotes: [String]
    let conflictTimes: [Double]
}

enum MeetingTranscriptFusion {
    static func fuse(local: [TranscriptSegment], external: [MeetingTranscriptSourceSegment]) -> MeetingTranscriptFusionResult {
        let localSources = local.enumerated().map { i, segment in
            MeetingTranscriptSourceSegment(id: "seg-\(i + 1)", source: "local",
                                           text: segment.text, speaker: segment.speakerName,
                                           capturedAt: segment.capturedAt)
        }
        return fuse(sourceSegments: localSources + external)
    }

    static func fuse(sourceSegments: [MeetingTranscriptSourceSegment]) -> MeetingTranscriptFusionResult {
        var retained: [MeetingTranscriptSourceSegment] = []
        var provenance: [String: [String]] = [:]
        var notes: [String] = []
        var conflictTimes: [Double] = []
        for candidate in sourceSegments.sorted(by: { ($0.capturedAt ?? .greatestFiniteMagnitude) < ($1.capturedAt ?? .greatestFiniteMagnitude) }) where !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let index = retained.firstIndex(where: { exactDuplicate($0, candidate) }) {
                let id = retained[index].id
                provenance[id, default: [id]].append(candidate.id)
                // Keep both provider lines in the accepted source revision.
                // Provenance is not a license to discard an original citation.
            }
            if let prior = retained.first(where: { $0.source != candidate.source && sameWindow($0, candidate) && similar($0.text, candidate.text) }), numericOrNegationDiffers(prior.text, candidate.text) {
                if let time = (prior.source == "local" ? prior : candidate).capturedAt { conflictTimes.append(time) }
                notes.append("未解決: \(prior.id) と \(candidate.id) で数字または否定表現が食い違います")
            }
            retained.append(candidate)
            provenance[candidate.id, default: [candidate.id]] = [candidate.id]
        }
        return MeetingTranscriptFusionResult(segments: retained, provenanceBySegmentID: provenance, unresolvedNotes: notes, conflictTimes: conflictTimes)
    }

    private static func sameWindow(_ a: MeetingTranscriptSourceSegment, _ b: MeetingTranscriptSourceSegment) -> Bool {
        guard let x = a.capturedAt, let y = b.capturedAt else { return false }
        return abs(x - y) <= 2.0
    }

    private static func exactDuplicate(_ a: MeetingTranscriptSourceSegment, _ b: MeetingTranscriptSourceSegment) -> Bool {
        guard sameWindow(a, b) else { return false }
        return a.text.trimmingCharacters(in: .whitespacesAndNewlines) == b.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        func grams(_ text: String) -> Set<String> {
            let letters = Array(text.lowercased().filter { $0.isLetter })
            guard letters.count >= 3 else { return [] }
            return Set((0..<(letters.count - 2)).map { String(letters[$0...($0 + 2)]) })
        }
        let x = grams(a), y = grams(b)
        return !x.isEmpty && Double(x.intersection(y).count) / Double(max(x.count, y.count)) >= 0.65
    }

    private static func numericOrNegationDiffers(_ lhs: String, _ rhs: String) -> Bool {
        let numbers: (String) -> [String] = { text in
            text.split { !$0.isNumber && $0 != "." }.map(String.init)
        }
        let negations: (String) -> Bool = { text in
            ["ない", "ません", "無", "not", "n't", "never", "no "].contains { text.localizedCaseInsensitiveContains($0) }
        }
        return numbers(lhs) != numbers(rhs) || negations(lhs) != negations(rhs)
    }
}
