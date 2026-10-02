import Foundation

/// A conservatively extracted, visible LINE body candidate.
///
/// This value is evidence only.  In particular, it does not assert a sender,
/// message time, or whether the text is newly arrived.
public struct LineBodyCandidate: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let text: String
    public let spanOrdinals: [Int]
    public let box: LineObservationRect
    public let extractionMethod: String
    public let sender: String?
    public let fromSelf: Bool?
    public let sentAt: Date?
    public let sentAtPrecision: String
    public let displayedTimeText: String?
    public let coverage: String

    public init(ordinal: Int, text: String, spanOrdinals: [Int], box: LineObservationRect,
                extractionMethod: String, sender: String? = nil, fromSelf: Bool? = nil,
                sentAt: Date? = nil, sentAtPrecision: String = "unknown",
                displayedTimeText: String? = nil, coverage: String = "visible_fragment") {
        self.ordinal = ordinal
        self.text = text
        self.spanOrdinals = spanOrdinals
        self.box = box
        self.extractionMethod = extractionMethod
        self.sender = sender
        self.fromSelf = fromSelf
        self.sentAt = sentAt
        self.sentAtPrecision = sentAtPrecision
        self.displayedTimeText = displayedTimeText
        self.coverage = coverage
    }
}

public enum LineBodyCandidateExtractor {
    private static let containmentTolerance = 0.002
    private static let singleSpanMethod = "ocr_span"

    /// Extracts visible-body candidates without deduplicating or inferring
    /// identity, timestamps, authorship, or arrival state.
    public static func extract(rows: [LineOCRRow],
                               textBlockRegions: [LineObservationRect] = [],
                               regionMethod: String = "ax_text_block") -> [LineBodyCandidate] {
        let validRows = rows.enumerated().compactMap { index, row -> (Int, LineOCRRow)? in
            isValid(row.box) ? (index, row) : nil
        }
        guard !validRows.isEmpty else { return [] }

        let validRegions = textBlockRegions.enumerated().compactMap { index, region -> (Int, LineObservationRect)? in
            isValid(region) ? (index, region) : nil
        }
        let overlappingRegionIndices = overlappingIndices(validRegions)

        var grouped: [Int: [(Int, LineOCRRow)]] = [:]
        var singles: [(Int, LineOCRRow)] = []
        for item in validRows {
            let matches = validRegions.filter { contains($0.1, item.1.box) }
            if matches.count == 1, !overlappingRegionIndices.contains(matches[0].0) {
                grouped[matches[0].0, default: []].append(item)
            } else {
                singles.append(item)
            }
        }

        var pending: [PendingCandidate] = []
        for (regionIndex, members) in grouped {
            guard validRegions.contains(where: { $0.0 == regionIndex }) else { continue }
            let ordered = members.sorted(by: rowOrder)
            pending.append(PendingCandidate(spanOrdinals: ordered.map(\.0),
                                            text: ordered.map { $0.1.text }.joined(separator: "\n"),
                                            box: union(ordered.map { $0.1.box }),
                                            extractionMethod: regionMethod))
        }
        pending.append(contentsOf: singles.map { index, row in
            PendingCandidate(spanOrdinals: [index], text: row.text, box: row.box,
                             extractionMethod: singleSpanMethod)
        })

        return pending.sorted(by: pendingOrder).enumerated().map { ordinal, candidate in
            LineBodyCandidate(ordinal: ordinal, text: candidate.text, spanOrdinals: candidate.spanOrdinals,
                              box: candidate.box, extractionMethod: candidate.extractionMethod,
                              coverage: "visible_fragment")
        }
    }

    private struct PendingCandidate {
        let spanOrdinals: [Int]
        let text: String
        let box: LineObservationRect
        let extractionMethod: String
    }

    private static func rowOrder(_ lhs: (Int, LineOCRRow), _ rhs: (Int, LineOCRRow)) -> Bool {
        if lhs.1.box.y != rhs.1.box.y { return lhs.1.box.y > rhs.1.box.y }
        if lhs.1.box.x != rhs.1.box.x { return lhs.1.box.x < rhs.1.box.x }
        return lhs.0 < rhs.0
    }

    private static func pendingOrder(_ lhs: PendingCandidate, _ rhs: PendingCandidate) -> Bool {
        if lhs.box.y != rhs.box.y { return lhs.box.y > rhs.box.y }
        if lhs.box.x != rhs.box.x { return lhs.box.x < rhs.box.x }
        return (lhs.spanOrdinals.first ?? .max) < (rhs.spanOrdinals.first ?? .max)
    }

    private static func isValid(_ rect: LineObservationRect) -> Bool {
        rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
        rect.width > 0 && rect.height > 0 && rect.x >= 0 && rect.y >= 0 &&
        rect.x + rect.width <= 1.002 && rect.y + rect.height <= 1.002
    }

    private static func contains(_ region: LineObservationRect, _ span: LineObservationRect) -> Bool {
        let tolerance = containmentTolerance
        return span.x >= region.x - tolerance && span.y >= region.y - tolerance &&
            span.x + span.width <= region.x + region.width + tolerance &&
            span.y + span.height <= region.y + region.height + tolerance
    }

    private static func overlappingIndices(_ regions: [(Int, LineObservationRect)]) -> Set<Int> {
        var result = Set<Int>()
        for lhs in regions.indices {
            for rhs in regions.index(after: lhs)..<regions.endIndex {
                if intersectionArea(regions[lhs].1, regions[rhs].1) > 0 {
                    result.insert(regions[lhs].0)
                    result.insert(regions[rhs].0)
                }
            }
        }
        return result
    }

    private static func intersectionArea(_ lhs: LineObservationRect, _ rhs: LineObservationRect) -> Double {
        let width = min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x)
        let height = min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y)
        return width > 0 && height > 0 ? width * height : 0
    }

    private static func union(_ boxes: [LineObservationRect]) -> LineObservationRect {
        let minX = boxes.map(\.x).min() ?? 0
        let minY = boxes.map(\.y).min() ?? 0
        let maxX = boxes.map { $0.x + $0.width }.max() ?? minX
        let maxY = boxes.map { $0.y + $0.height }.max() ?? minY
        return LineObservationRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
