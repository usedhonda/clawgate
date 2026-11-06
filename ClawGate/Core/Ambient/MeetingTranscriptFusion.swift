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
    /// Comparison-only clocks; original timestamps never change.
    var clockOffsetsBySource: [String: Double] = [:]
}

enum MeetingTranscriptFusion {
    static func fuse(local: [TranscriptSegment], external: [MeetingTranscriptSourceSegment]) -> MeetingTranscriptFusionResult {
        fuse(local: local, external: external, checkingCancellation: {})
    }

    static func fuse(local: [TranscriptSegment], external: [MeetingTranscriptSourceSegment],
                     checkingCancellation: () throws -> Void) rethrows -> MeetingTranscriptFusionResult {
        let localSources = try local.enumerated().map { index, segment in
            try checkingCancellation()
            return MeetingTranscriptSourceSegment(id: "seg-\(index + 1)", source: "local",
                                           text: segment.text, speaker: segment.speakerName,
                                           capturedAt: segment.capturedAt)
        }
        return try fuse(sourceSegments: localSources + external, checkingCancellation: checkingCancellation)
    }

    static func fuse(sourceSegments: [MeetingTranscriptSourceSegment]) -> MeetingTranscriptFusionResult {
        fuse(sourceSegments: sourceSegments, checkingCancellation: {})
    }

    static func fuse(sourceSegments: [MeetingTranscriptSourceSegment],
                     checkingCancellation: () throws -> Void) rethrows -> MeetingTranscriptFusionResult {
        let offsets = try clockOffsets(sourceSegments, checkingCancellation: checkingCancellation)
        func aligned(_ segment: MeetingTranscriptSourceSegment) -> Double? {
            segment.capturedAt.map { $0 + (offsets[clockKey(segment)] ?? 0) }
        }
        func overlaps(_ a: MeetingTranscriptSourceSegment, _ b: MeetingTranscriptSourceSegment) -> Bool {
            guard let x = aligned(a), let y = aligned(b) else { return false }
            return abs(x - y) <= 2
        }
        var retained: [MeetingTranscriptSourceSegment] = []
        var provenance: [String: [String]] = [:]
        var notes: [String] = []
        var conflictTimes: [Double] = []
        for candidate in sourceSegments.sorted(by: { (aligned($0) ?? .greatestFiniteMagnitude) < (aligned($1) ?? .greatestFiniteMagnitude) }) where !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try checkingCancellation()
            if let index = try retained.firstIndex(where: { try checkingCancellation(); return clockKey($0) != clockKey(candidate) && overlaps($0, candidate) && normalized($0.text) == normalized(candidate.text) }) {
                let id = retained[index].id
                provenance[id, default: [id]].append(candidate.id)
                // Keep both provider lines in the accepted source revision.
                // Provenance is not a license to discard an original citation.
            }
            if let prior = try retained.first(where: { try checkingCancellation(); return $0.source != candidate.source && overlaps($0, candidate) && similar($0.text, candidate.text) }), numericOrNegationDiffers(prior.text, candidate.text) {
                if let time = (prior.source == "local" ? prior : candidate).capturedAt { conflictTimes.append(time) }
                notes.append("未解決: \(prior.id) と \(candidate.id) で数字または否定表現が食い違います")
            }
            retained.append(candidate)
            provenance[candidate.id, default: [candidate.id]] = [candidate.id]
        }
        return MeetingTranscriptFusionResult(segments: retained, provenanceBySegmentID: provenance, unresolvedNotes: notes, conflictTimes: conflictTimes, clockOffsetsBySource: offsets)
    }

    /// Prompt-only grouping. Every original remains in the durable envelope.
    /// A complete line may match up to three adjacent lines in another stream;
    /// ambiguous repeated matches and untimed/secondary evidence stay separate.
    static func equivalentGroups(_ segments: [MeetingTranscriptSourceSegment]) -> [[String]] {
        let offsets = clockOffsets(segments, checkingCancellation: {})
        func time(_ segment: MeetingTranscriptSourceSegment) -> Double? {
            segment.capturedAt.map { $0 + (offsets[clockKey(segment)] ?? 0) }
        }
        let streams = Dictionary(grouping: segments.indices.filter {
            time(segments[$0]) != nil && segments[$0].source != "existing-minutes"
        }, by: { clockKey(segments[$0]) }).mapValues { indices in
            indices.sorted { (time(segments[$0])!, $0) < (time(segments[$1])!, $1) }
        }
        var windows: [String: [[Int]]] = [:]
        for key in streams.keys.sorted() {
            let indices = streams[key]!
            for start in indices.indices {
                for count in 1...min(3, indices.count - start) {
                    let slice = Array(indices[start..<(start + count)])
                    guard zip(slice, slice.dropFirst()).allSatisfy({
                        time(segments[$1])! - time(segments[$0])! <= 2
                    }) else { break }
                    let texts = slice.map { segments[$0].text }
                    let canJoinWithoutSpace = zip(texts, texts.dropFirst()).allSatisfy { a, b in
                        guard let last = a.last, let first = b.first else { return false }
                        return !(last.isASCII && first.isASCII && (last.isLetter || last.isNumber) && (first.isLetter || first.isNumber))
                    }
                    var forms = Set([normalized(texts.joined(separator: " "))])
                    if canJoinWithoutSpace { forms.insert(normalized(texts.joined())) }
                    for text in forms where !text.isEmpty {
                        windows[text, default: []].append(slice)
                    }
                }
            }
        }
        var used = Set<Int>()
        var grouped: [(Int, [String])] = []
        // Prefer complete lines over fragments, without changing the source order
        // of the returned groups. Equal-length ties retain the input order.
        let anchors = segments.indices.sorted {
            segments[$0].text.count == segments[$1].text.count ? $0 < $1 : segments[$0].text.count > segments[$1].text.count
        }
        for index in anchors where !used.contains(index) {
            let anchor = segments[index]
            var members = [index]
            if let anchorTime = time(anchor), anchor.source != "existing-minutes" {
                let candidates = (windows[normalized(anchor.text)] ?? []).filter { slice in
                    clockKey(segments[slice[0]]) != clockKey(anchor) &&
                    slice.allSatisfy { !used.contains($0) } &&
                    abs(time(segments[slice[0]])! - anchorTime) <= 2 &&
                    slice.allSatisfy {
                        anchor.speaker == nil || segments[$0].speaker == nil || anchor.speaker == segments[$0].speaker
                    }
                }
                let byStream = Dictionary(grouping: candidates, by: { clockKey(segments[$0[0]]) })
                for key in byStream.keys.sorted() {
                    if let matches = byStream[key], matches.count == 1 { members += matches[0] }
                }
            }
            used.formUnion(members)
            grouped.append((members.min()!, members.map { segments[$0].id }))
        }
        return grouped.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func clockKey(_ segment: MeetingTranscriptSourceSegment) -> String {
        segment.source + ":" + (segment.recallLineage?.eventID ?? segment.sourceURL ?? "")
    }

    private static func normalized(_ text: String) -> String {
        // Keep punctuation (including minus and decimal signs) and negation.
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func clockOffsets(_ segments: [MeetingTranscriptSourceSegment],
                                     checkingCancellation: () throws -> Void) rethrows -> [String: Double] {
        try checkingCancellation()
        let streams = Dictionary(grouping: segments.filter { $0.capturedAt != nil }, by: clockKey)
        let keys = streams.keys.sorted { a, b in
            if a.hasPrefix("local:") != b.hasPrefix("local:") { return a.hasPrefix("local:") }
            return a < b
        }
        guard let reference = keys.first, let original = streams[reference] else { return [:] }
        let anchors = Dictionary(grouping: original, by: { normalized($0.text) })
        var result: [String: Double] = [:]
        for key in keys.dropFirst() {
            try checkingCancellation()
            let candidates = Dictionary(grouping: streams[key] ?? [], by: { normalized($0.text) })
            let pairs = candidates.compactMap { text, lines -> (Double, Double)? in
                guard text.count >= 12, lines.count == 1, let match = anchors[text], match.count == 1,
                      let x = match[0].capturedAt, let y = lines[0].capturedAt else { return nil }
                return (x, y)
            }.sorted { $0.0 < $1.0 }
            guard pairs.count >= 3,
                  zip(pairs, pairs.dropFirst()).allSatisfy({ $0.0.0 < $0.1.0 && $0.0.1 < $0.1.1 }) else { continue }
            let deltas = pairs.map { $0.0 - $0.1 }.sorted()
            let median = deltas[deltas.count / 2]
            guard deltas.allSatisfy({ abs($0 - median) <= 2 }) else { continue }
            result[key] = median
        }
        return result
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
