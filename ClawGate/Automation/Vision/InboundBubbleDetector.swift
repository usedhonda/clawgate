import AppKit

/// Finds LINE's incoming neutral-gray message bubbles without OCR.
///
/// This is deliberately a fail-closed pixel detector. It is intended to find
/// a crop for a later OCR pass, not to decide whether a bubble contains text.
enum InboundBubbleDetector {
    struct Detection {
        let rects: [CGRect]
        let status: Status
    }

    enum Status: Equatable {
        case ready
        case noBubbles
        case uncertain
    }

    private struct Candidate {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var neutralCount: Int
    }

    /// Returns tight body rectangles in original-image, top-down pixel space.
    /// Unsupported layouts, clipped candidates, or ambiguous geometry return
    /// `uncertain` with no rectangles. No OCR or text-content fallback occurs.
    static func detect(in image: CGImage) -> Detection {
        guard image.width > 0, image.height > 0,
              let raster = Raster(image: image) else {
            return Detection(rects: [], status: .uncertain)
        }

        // Segment at <=800px per axis. Integer sampling keeps the coordinate
        // mapping stable; accepted edges are refined against the source raster
        // in narrow bands below.
        let sampleFactor = max(1, (max(image.width, image.height) + 799) / 800)
        let sampleWidth = (image.width + sampleFactor - 1) / sampleFactor
        let sampleHeight = (image.height + sampleFactor - 1) / sampleFactor
        let mask = raster.sampledMask(factor: sampleFactor, width: sampleWidth, height: sampleHeight)
        var visited = Array(repeating: UInt8(0), count: mask.count)
        var candidates: [Candidate] = []
        for start in 0..<mask.count where mask[start] != 0 && visited[start] == 0 {
            var queue = [start]
            visited[start] = 1
            var cursor = 0
            var minX = start % sampleWidth
            var maxX = minX
            var minY = start / sampleWidth
            var maxY = minY
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % sampleWidth
                let y = index / sampleWidth
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                if x > 0 {
                    let next = index - 1
                    if mask[next] != 0 && visited[next] == 0 { visited[next] = 1; queue.append(next) }
                }
                if x + 1 < sampleWidth {
                    let next = index + 1
                    if mask[next] != 0 && visited[next] == 0 { visited[next] = 1; queue.append(next) }
                }
                if y > 0 {
                    let next = index - sampleWidth
                    if mask[next] != 0 && visited[next] == 0 { visited[next] = 1; queue.append(next) }
                }
                if y + 1 < sampleHeight {
                    let next = index + sampleWidth
                    if mask[next] != 0 && visited[next] == 0 { visited[next] = 1; queue.append(next) }
                }
            }
            candidates.append(Candidate(
                minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                neutralCount: queue.count
            ))
        }

        var rects: [CGRect] = []
        var ambiguous = false
        for candidate in candidates {
            switch validate(candidate, mask: mask, width: sampleWidth, height: sampleHeight) {
            case .accept:
                rects.append(toOriginalRect(candidate, mask: mask, width: sampleWidth, factor: sampleFactor, raster: raster))
            case .ambiguous:
                ambiguous = true
            case .reject:
                break
            }
        }

        if !rects.isEmpty {
            return Detection(rects: rects.sorted { $0.minY < $1.minY }, status: .ready)
        }
        let supportedCanvas = raster.lightCanvasFraction(factor: sampleFactor) >= 0.25
        return Detection(rects: [], status: ambiguous || !supportedCanvas ? .uncertain : .noBubbles)
    }

    private enum Validation { case accept, reject, ambiguous }

    private static func validate(_ c: Candidate, mask: [UInt8], width: Int, height: Int) -> Validation {
        let boxWidth = c.maxX - c.minX + 1
        let boxHeight = c.maxY - c.minY + 1
        let imageWidth = Double(width)
        guard boxWidth >= max(18, Int(imageWidth * 0.018)), boxHeight >= 10 else { return .reject }
        // The avatar lane is outside the incoming body lane, even for gray icons.
        guard c.minX >= Int(imageWidth * 0.035), c.minX <= Int(imageWidth * 0.38),
              c.maxX < Int(imageWidth * 0.96) else { return .reject }
        guard c.minY > 1, c.maxY < height - 2 else { return .ambiguous }
        guard Double(c.neutralCount) / Double(boxWidth * boxHeight) >= 0.48 else { return .reject }

        // A bubble has fill at the middle of each horizontal edge but not at
        // all four rounded corners. This rejects flat separators and dates.
        // Radius scales with the sampled bubble. A fixed 12px window rejects
        // the same bubble at 2x capture scale after downsampling.
        let cornerExtent = max(2, boxHeight / 6)
        let cornerW = cornerExtent
        let cornerH = cornerExtent
        var cornerFill = 0
        var cornerArea = 0
        for y in c.minY...c.maxY {
            for x in c.minX...c.maxX {
                let inCorner = (x - c.minX < cornerW || c.maxX - x < cornerW) &&
                    (y - c.minY < cornerH || c.maxY - y < cornerH)
                if inCorner {
                    cornerArea += 1
                    if mask[y * width + x] != 0 { cornerFill += 1 }
                }
            }
        }
        guard Double(cornerFill) / Double(max(1, cornerArea)) < 0.82 else { return .reject }

        // Centered gray day labels are not inbound lane content. A candidate
        // that is both centered and short is treated as unsupported rather
        // than guessed into a message crop.
        let center = Double(c.minX + c.maxX) / 2.0
        if abs(center - imageWidth / 2.0) < imageWidth * 0.12 &&
            Double(boxWidth) < imageWidth * 0.55 {
            return .reject
        }
        return .accept
    }

    private static func toOriginalRect(_ c: Candidate, mask: [UInt8], width: Int, factor: Int, raster: Raster) -> CGRect {
        // LINE's incoming tail is part of the same fill component, but it is
        // not useful OCR crop area. Keep columns with substantial vertical
        // support; this also leaves a small flat-fill margin around glyphs.
        let height = c.maxY - c.minY + 1
        let supportThreshold = max(2, Int(Double(height) * 0.35))
        var bodyMinX = c.minX
        var bodyMaxX = c.maxX
        for x in c.minX...c.maxX {
            let support = (c.minY...c.maxY).reduce(into: 0) { count, y in
                if mask[y * width + x] != 0 { count += 1 }
            }
            if support >= supportThreshold {
                bodyMinX = x
                break
            }
        }
        for x in stride(from: c.maxX, through: c.minX, by: -1) {
            let support = (c.minY...c.maxY).reduce(into: 0) { count, y in
                if mask[y * width + x] != 0 { count += 1 }
            }
            if support >= supportThreshold {
                bodyMaxX = x
                break
            }
        }
        var minX = min(raster.width - 1, bodyMinX * factor)
        var maxX = min(raster.width - 1, (bodyMaxX + 1) * factor - 1)
        var minY = min(raster.height - 1, c.minY * factor)
        var maxY = min(raster.height - 1, (c.maxY + 1) * factor - 1)
        let xBand = max(1, factor * 2)
        let yBand = max(1, factor * 2)
        let sourceMinX = max(0, minX - xBand)...min(raster.width - 1, minX + xBand)
        let sourceMaxX = max(0, maxX - xBand)...min(raster.width - 1, maxX + xBand)
        let sourceMinY = max(0, minY - yBand)...min(raster.height - 1, minY + yBand)
        let sourceMaxY = max(0, maxY - yBand)...min(raster.height - 1, maxY + yBand)
        let ySupport = max(2, Int(Double(maxY - minY + 1) * 0.35))
        let xSupport = max(2, Int(Double(maxX - minX + 1) * 0.35))
        if let refined = raster.firstColumn(in: sourceMinX, y: minY...maxY, minimum: ySupport) { minX = refined }
        if let refined = raster.lastColumn(in: sourceMaxX, y: minY...maxY, minimum: ySupport) { maxX = refined }
        if let refined = raster.firstRow(in: sourceMinY, x: minX...maxX, minimum: xSupport) { minY = refined }
        if let refined = raster.lastRow(in: sourceMaxY, x: minX...maxX, minimum: xSupport) { maxY = refined }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private struct Raster {
        let width: Int
        let height: Int
        private let bytes: [UInt8]

        init?(image: CGImage) {
            width = image.width
            height = image.height
            var rendered = Array(repeating: UInt8(0), count: width * height * 4)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: &rendered, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytes = rendered
        }

        func sampledMask(factor: Int, width: Int, height: Int) -> [UInt8] {
            var mask = Array(repeating: UInt8(0), count: width * height)
            for y in 0..<height {
                let sourceY = min(self.height - 1, y * factor + factor / 2)
                for x in 0..<width {
                    let sourceX = min(self.width - 1, x * factor + factor / 2)
                    mask[y * width + x] = isNeutral(sourceX, sourceY) ? 1 : 0
                }
            }
            return mask
        }

        func lightCanvasFraction(factor: Int) -> Double {
            let step = max(1, factor)
            var light = 0
            var total = 0
            for y in stride(from: step / 2, to: height, by: step) {
                for x in stride(from: step / 2, to: width, by: step) {
                    total += 1
                    if isLightCanvas(x, y) { light += 1 }
                }
            }
            return total == 0 ? 0 : Double(light) / Double(total)
        }

        func firstColumn(in range: ClosedRange<Int>, y: ClosedRange<Int>, minimum: Int) -> Int? {
            for x in range where y.reduce(into: 0, { if isNeutral(x, $1) { $0 += 1 } }) >= minimum { return x }
            return nil
        }

        func lastColumn(in range: ClosedRange<Int>, y: ClosedRange<Int>, minimum: Int) -> Int? {
            for x in range.reversed() where y.reduce(into: 0, { if isNeutral(x, $1) { $0 += 1 } }) >= minimum { return x }
            return nil
        }

        func firstRow(in range: ClosedRange<Int>, x: ClosedRange<Int>, minimum: Int) -> Int? {
            for y in range where x.reduce(into: 0, { if isNeutral($1, y) { $0 += 1 } }) >= minimum { return y }
            return nil
        }

        func lastRow(in range: ClosedRange<Int>, x: ClosedRange<Int>, minimum: Int) -> Int? {
            for y in range.reversed() where x.reduce(into: 0, { if isNeutral($1, y) { $0 += 1 } }) >= minimum { return y }
            return nil
        }

        private func isNeutral(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * width + x) * 4
            let r = Int(bytes[offset])
            let g = Int(bytes[offset + 1])
            let b = Int(bytes[offset + 2])
            let spread = max(r, max(g, b)) - min(r, min(g, b))
            let luma = (r + g + b) / 3
            return spread <= 10 && luma >= 215 && luma <= 248
        }

        private func isLightCanvas(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * width + x) * 4
            let r = Int(bytes[offset])
            let g = Int(bytes[offset + 1])
            let b = Int(bytes[offset + 2])
            let spread = max(r, max(g, b)) - min(r, min(g, b))
            return spread <= 10 && (r + g + b) / 3 >= 249
        }
    }
}
