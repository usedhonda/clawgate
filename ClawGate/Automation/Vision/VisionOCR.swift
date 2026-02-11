import AppKit
import Vision

/// Extracts text from screen regions using Vision framework OCR.
/// Requires Screen Recording permission for CGWindowListCreateImage.
/// Gracefully returns nil when permission is not granted.
enum VisionOCR {

    /// Extract text from a screen rectangle (in global CG coordinates).
    /// Returns nil if Screen Recording permission is missing or OCR fails.
    /// When windowID is provided, captures only that window (immune to occlusion).
    /// When windowID is kCGNullWindowID (default), captures on-screen composite.
    static func extractText(from screenRect: CGRect, windowID: CGWindowID = kCGNullWindowID) -> String? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else {
            return nil
        }
        return performOCR(on: image)
    }

    /// OCR for LINE inbound text:
    /// suppress outgoing (green) bubble content before OCR so incoming gray bubbles dominate.
    static func extractTextLineInbound(from screenRect: CGRect, windowID: CGWindowID = kCGNullWindowID) -> String? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else {
            return nil
        }
        guard let masked = preprocessInboundOCRImage(image) else {
            return performOCR(on: image)
        }
        return performOCR(on: masked)
    }

    /// Extract text from multiple screen rectangles merged into one capture (with padding).
    /// More efficient than calling extractText(from:) per-rect: N rects × 300ms → 1 capture × 300ms.
    static func extractText(from rects: [CGRect], padding: CGFloat = 4, windowID: CGWindowID = kCGNullWindowID) -> String? {
        guard !rects.isEmpty else { return nil }
        let merged = rects.reduce(rects[0]) { $0.union($1) }
        let padded = merged.insetBy(dx: -padding, dy: -padding)
        return extractText(from: padded, windowID: windowID)
    }

    // MARK: - Private

    private static func captureImage(from screenRect: CGRect, windowID: CGWindowID) -> CGImage? {
        let options: CGWindowListOption = windowID != kCGNullWindowID
            ? .optionIncludingWindow
            : .optionOnScreenOnly
        guard let image = CGWindowListCreateImage(
            screenRect,
            options,
            windowID,
            [.bestResolution]
        ) else {
            return nil
        }
        // Zero-size image means Screen Recording permission is likely missing
        if image.width == 0 || image.height == 0 {
            return nil
        }
        return image
    }

    private static func preprocessInboundOCRImage(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Seed 1: outgoing green bubble area.
        var greenSeedMask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let i = rowOffset + x * 4
                let r = buffer[i]
                let g = buffer[i + 1]
                let b = buffer[i + 2]
                if isOutgoingGreenSeed(r: r, g: g, b: b) {
                    greenSeedMask[y * width + x] = 1
                }
            }
        }

        // Expand 3px around green regions to erase anti-aliased outgoing text edges.
        let radius = 3
        var expandedGreenMask = greenSeedMask
        for y in 0..<height {
            for x in 0..<width {
                if greenSeedMask[y * width + x] == 0 { continue }
                let minY = max(0, y - radius)
                let maxY = min(height - 1, y + radius)
                let minX = max(0, x - radius)
                let maxX = min(width - 1, x + radius)
                for yy in minY...maxY {
                    for xx in minX...maxX {
                        expandedGreenMask[yy * width + xx] = 1
                    }
                }
            }
        }

        // Seed 2: light-gray UI artifacts (timestamp/read line/unread separators).
        var lightGrayMask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let i = rowOffset + x * 4
                let r = buffer[i]
                let g = buffer[i + 1]
                let b = buffer[i + 2]
                if isLightGrayUIArtifact(r: r, g: g, b: b) {
                    lightGrayMask[y * width + x] = 1
                }
            }
        }

        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let i = rowOffset + x * 4
                if expandedGreenMask[y * width + x] == 1 {
                    // Flatten outgoing side to uniform green so own-side text is not OCR'ed.
                    buffer[i] = 186
                    buffer[i + 1] = 230
                    buffer[i + 2] = 164
                    continue
                }
                if lightGrayMask[y * width + x] == 1 {
                    // Whiten noisy light-gray UI glyphs/lines.
                    buffer[i] = 246
                    buffer[i + 1] = 246
                    buffer[i + 2] = 246
                }
            }
        }

        return ctx.makeImage()
    }

    private static func isOutgoingGreenSeed(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        let ri = Int(r)
        let gi = Int(g)
        let bi = Int(b)

        // Fixed color band from LINE outgoing bubble sample:
        // center ~= (196, 232, 160)
        let nearBubbleCenter = abs(ri - 196) <= 44
            && abs(gi - 232) <= 28
            && abs(bi - 160) <= 52
        if nearBubbleCenter {
            return true
        }

        // Fast RGB guard tuned for LINE outgoing bubble shades.
        let rgbMatch = gi >= 120 && gi <= 244
            && ri >= 118 && ri <= 228
            && bi >= 110 && bi <= 210
            && gi >= ri + 8
            && gi >= bi + 12

        if rgbMatch {
            return true
        }

        // Hue fallback for anti-aliased edge pixels near bubble/text boundary.
        let (h, s, v) = rgbToHSV(r: r, g: g, b: b)
        return (h >= 78 && h <= 150) && s >= 0.12 && v >= 0.40
    }

    private static func isLightGrayUIArtifact(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        let ri = Int(r)
        let gi = Int(g)
        let bi = Int(b)
        let maxC = max(ri, max(gi, bi))
        let minC = min(ri, min(gi, bi))
        let sat = maxC - minC
        let luminance = (299 * ri + 587 * gi + 114 * bi) / 1000
        // Keep this narrow so inbound bubble body is not erased.
        return sat <= 10 && luminance >= 188 && luminance <= 232
    }

    private static func rgbToHSV(r: UInt8, g: UInt8, b: UInt8) -> (h: Double, s: Double, v: Double) {
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0
        let maxV = max(rf, max(gf, bf))
        let minV = min(rf, min(gf, bf))
        let delta = maxV - minV

        var hue: Double = 0
        if delta != 0 {
            if maxV == rf {
                hue = 60 * (((gf - bf) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxV == gf {
                hue = 60 * (((bf - rf) / delta) + 2)
            } else {
                hue = 60 * (((rf - gf) / delta) + 4)
            }
        }
        if hue < 0 { hue += 360 }
        let saturation = maxV == 0 ? 0 : delta / maxV
        return (h: hue, s: saturation, v: maxV)
    }

    private static func performOCR(on image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else {
            return nil
        }

        let texts = observations.compactMap { observation -> String? in
            let candidates = observation.topCandidates(3)
            if let accepted = candidates.first(where: { $0.confidence >= 0.34 }) {
                return accepted.string
            }
            // Keep best candidate as fallback to avoid dropping long/complex Japanese text.
            return candidates.first?.string
        }
        guard !texts.isEmpty else {
            return nil
        }

        return texts.joined(separator: "\n")
    }
}
