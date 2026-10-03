import Foundation

/// An annotation retained alongside visible body candidates.  It is evidence
/// only; it never asserts sender, read state, or a native message timestamp.
public struct LineVisibleAnnotation: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let text: String
    public let spanOrdinals: [Int]
    public let box: LineObservationRect
    public let kind: String
    public let evidence: String
    public let relatedBodyOrdinal: Int?

    public init(ordinal: Int, text: String, spanOrdinals: [Int], box: LineObservationRect,
                kind: String, evidence: String, relatedBodyOrdinal: Int? = nil) {
        self.ordinal = ordinal
        self.text = text
        self.spanOrdinals = spanOrdinals
        self.box = box
        self.kind = kind
        self.evidence = evidence
        self.relatedBodyOrdinal = relatedBodyOrdinal
    }
}

public struct LineVisibleContentExtraction: Codable, Equatable, Sendable {
    public let bodyCandidates: [LineBodyCandidate]
    public let annotations: [LineVisibleAnnotation]

    public init(bodyCandidates: [LineBodyCandidate], annotations: [LineVisibleAnnotation] = []) {
        self.bodyCandidates = bodyCandidates
        self.annotations = annotations
    }

}

/// Conservative, geometry-only grouping for OCR text that is visible in a
/// LINE conversation.  This deliberately does not infer identity or sentAt.
public enum LineVisibleContentExtractor {
    private static let xTolerance = 0.015

    public static func extract(rows: [LineOCRRow], textBlockRegions: [LineObservationRect] = [],
                               regionMethod: String = "ax_text_block") -> LineVisibleContentExtraction {
        let valid = rows.enumerated().filter { isValid($0.element.box) }
        guard !valid.isEmpty else { return LineVisibleContentExtraction(bodyCandidates: []) }

        let hasValidRegions = textBlockRegions.contains(where: isValid)
        let base: [LineBodyCandidate]
        if hasValidRegions {
            let grouped = LineBodyCandidateExtractor.extract(rows: rows, textBlockRegions: textBlockRegions,
                                                               regionMethod: regionMethod)
            base = grouped.flatMap { candidate -> [LineBodyCandidate] in
                guard candidate.text.utf16.count > 4000 else { return [candidate] }
                return candidate.spanOrdinals.map { ordinal in
                    LineBodyCandidate(ordinal: ordinal, text: rows[ordinal].text, spanOrdinals: [ordinal],
                                      box: rows[ordinal].box, extractionMethod: "ocr_span")
                }
            }.enumerated().map { ordinal, candidate in
                LineBodyCandidate(ordinal: ordinal, text: candidate.text, spanOrdinals: candidate.spanOrdinals,
                                  box: candidate.box, extractionMethod: candidate.extractionMethod)
            }
        } else {
            base = alignedCandidates(validRows: valid)
        }

        var candidates = base
        var annotations: [LineVisibleAnnotation] = []
        let typicalHeight = median(valid.map { $0.element.box.height })
        let bodyRows = valid.filter { $0.element.box.height >= typicalHeight * 0.85 }
        var clockMatches: [Int: LineBodyCandidate] = [:]
        for (ordinal, row) in valid where isClock(row.text) && row.box.height <= typicalHeight * 0.85 {
            if base.contains(where: { $0.spanOrdinals == [ordinal] }),
               let body = uniqueClockMatch(row: row, sourceOrdinal: ordinal, candidates: base, typicalHeight: typicalHeight) {
                clockMatches[ordinal] = body
            }
        }
        let clocksPerBody = Dictionary(grouping: clockMatches.values, by: \.ordinal).mapValues(\.count)

        for (sourceOrdinal, row) in valid {
            if let match = clockMatches[sourceOrdinal], clocksPerBody[match.ordinal] == 1 {
                guard let matchIndex = candidates.firstIndex(where: { $0.ordinal == match.ordinal }) else { continue }
                let updated = LineBodyCandidate(ordinal: match.ordinal, text: match.text,
                    spanOrdinals: match.spanOrdinals.filter { $0 != sourceOrdinal }, box: match.box,
                    extractionMethod: match.extractionMethod, sender: match.sender, fromSelf: match.fromSelf,
                    sentAt: match.sentAt, sentAtPrecision: match.sentAtPrecision,
                    displayedTimeText: row.text, coverage: match.coverage)
                candidates[matchIndex] = updated
                candidates.removeAll { $0.spanOrdinals == [sourceOrdinal] }
                annotations.append(LineVisibleAnnotation(ordinal: annotations.count, text: row.text,
                    spanOrdinals: [sourceOrdinal], box: row.box, kind: "displayed_time",
                    evidence: "ocr_clock_badge_layout", relatedBodyOrdinal: match.ordinal))
            } else if isUnreadDivider(row.text), candidates.contains(where: { $0.spanOrdinals == [sourceOrdinal] }),
                      isCenteredDivider(row: row, bodyRows: bodyRows, typicalHeight: typicalHeight) {
                annotations.append(LineVisibleAnnotation(ordinal: annotations.count, text: row.text,
                    spanOrdinals: [sourceOrdinal], box: row.box, kind: "unread_divider",
                    evidence: "ocr_centered_divider"))
                candidates.removeAll { $0.spanOrdinals == [sourceOrdinal] }
            }
        }
        return LineVisibleContentExtraction(bodyCandidates: candidates, annotations: annotations)
    }

    private static func alignedCandidates(validRows: [(offset: Int, element: LineOCRRow)]) -> [LineBodyCandidate] {
        let ordered = validRows.sorted { lhs, rhs in
            lhs.element.box.y != rhs.element.box.y ? lhs.element.box.y > rhs.element.box.y : lhs.element.box.x < rhs.element.box.x
        }
        var groups: [[(Int, LineOCRRow)]] = []
        for item in ordered {
            guard var last = groups.last, let previous = last.last else {
                groups.append([(item.offset, item.element)]); continue
            }
            let gap = previous.1.box.y - (item.element.box.y + item.element.box.height)
            let sizeRatio = item.element.box.height / max(previous.1.box.height, 0.0001)
            let aligned = abs(item.element.box.x - previous.1.box.x) <= xTolerance &&
                gap <= 0.5 * max(item.element.box.height, previous.1.box.height) &&
                gap >= -0.15 * min(item.element.box.height, previous.1.box.height) &&
                sizeRatio >= 0.75 && sizeRatio <= 1.33
            let combinedLength = last.reduce(0) { $0 + $1.1.text.utf16.count } + last.count + item.element.text.utf16.count
            if aligned && combinedLength <= 4000 { last.append((item.offset, item.element)); groups[groups.count - 1] = last }
            else { groups.append([(item.offset, item.element)]) }
        }
        return groups.sorted { ($0.first?.1.box.y ?? 0) > ($1.first?.1.box.y ?? 0) }.enumerated().map { ordinal, group in
            let sorted = group.sorted { $0.1.box.y > $1.1.box.y }
            return LineBodyCandidate(ordinal: ordinal, text: sorted.map { $0.1.text }.joined(separator: "\n"),
                spanOrdinals: sorted.map { $0.0 }, box: union(sorted.map { $0.1.box }),
                extractionMethod: sorted.count > 1 ? "ocr_aligned_lines" : "ocr_span", coverage: "visible_fragment")
        }
    }

    private static func uniqueClockMatch(row: LineOCRRow, sourceOrdinal: Int, candidates: [LineBodyCandidate], typicalHeight: Double) -> LineBodyCandidate? {
        let matches = candidates.filter { candidate in
            candidate.spanOrdinals.count >= 2 && !candidate.spanOrdinals.contains(sourceOrdinal) &&
            ((row.box.x >= candidate.box.x + candidate.box.width && row.box.x - (candidate.box.x + candidate.box.width) <= 0.20) ||
             (candidate.box.x >= row.box.x + row.box.width && candidate.box.x - (row.box.x + row.box.width) <= 0.20))
        }.filter { candidate in
            // Badges overlap the last text line vertically but sit outside the
            // body horizontally. Compare lower edges, never the block's top.
            let endGap = row.box.y - candidate.box.y
            return endGap >= -1.5 * typicalHeight && endGap <= 0.25 * typicalHeight
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func isClock(_ text: String) -> Bool {
        text.range(of: #"^(午前|午後)\s*([0-9]|1[0-2]):[0-5][0-9]$"#, options: .regularExpression) != nil
    }

    private static func isUnreadDivider(_ text: String) -> Bool { text == "ここから未読メッセージ" }

    private static func isCenteredDivider(row: LineOCRRow, bodyRows: [(offset: Int, element: LineOCRRow)], typicalHeight: Double) -> Bool {
        guard row.box.width <= 0.5, row.box.height <= typicalHeight * 0.9 else { return false }
        let others = bodyRows.filter { $0.element != row }
        guard !others.contains(where: { $0.element.box.y < row.box.y + row.box.height && $0.element.box.y + $0.element.box.height > row.box.y }) else { return false }
        let neighbors = others.filter { $0.element.box.y + $0.element.box.height <= row.box.y || $0.element.box.y >= row.box.y + row.box.height }
        guard let nearest = neighbors.min(by: { abs($0.element.box.y - row.box.y) < abs($1.element.box.y - row.box.y) }) else { return false }
        let center = row.box.x + row.box.width / 2
        let bodyCenter = nearest.element.box.x + nearest.element.box.width / 2
        let gap = nearest.element.box.y + nearest.element.box.height <= row.box.y ? row.box.y - (nearest.element.box.y + nearest.element.box.height) : nearest.element.box.y - (row.box.y + row.box.height)
        return abs(center - 0.5) <= 0.10 && abs(center - bodyCenter) <= 0.20 && gap >= typicalHeight
    }

    private static func isValid(_ rect: LineObservationRect) -> Bool {
        rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0 && rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= 1.002 && rect.y + rect.height <= 1.002
    }

    private static func median(_ values: [Double]) -> Double { let s = values.sorted(); return s.isEmpty ? 0.05 : s[s.count / 2] }
    private static func union(_ boxes: [LineObservationRect]) -> LineObservationRect { let minX = boxes.map(\.x).min() ?? 0; let minY = boxes.map(\.y).min() ?? 0; let maxX = boxes.map { $0.x + $0.width }.max() ?? minX; let maxY = boxes.map { $0.y + $0.height }.max() ?? minY; return LineObservationRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
}
