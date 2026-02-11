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
        guard let masked = maskOutgoingGreenBubbleText(image) else {
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

    private static func maskOutgoingGreenBubbleText(_ image: CGImage) -> CGImage? {
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

        var seedMask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let i = rowOffset + x * 4
                let r = buffer[i]
                let g = buffer[i + 1]
                let b = buffer[i + 2]
                // LINE outgoing bubble green-ish range
                if g > 118 && g > r &+ 10 && g > b &+ 16 {
                    seedMask[y * width + x] = 1
                }
            }
        }

        // Expand mask around green areas to cover nearby anti-aliased text edges.
        let radius = 3
        var expandedMask = seedMask
        for y in 0..<height {
            for x in 0..<width {
                if seedMask[y * width + x] == 0 { continue }
                let minY = max(0, y - radius)
                let maxY = min(height - 1, y + radius)
                let minX = max(0, x - radius)
                let maxX = min(width - 1, x + radius)
                for yy in minY...maxY {
                    for xx in minX...maxX {
                        expandedMask[yy * width + xx] = 1
                    }
                }
            }
        }

        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                if expandedMask[y * width + x] == 0 { continue }
                let i = rowOffset + x * 4
                // Flatten to uniform light green so outgoing-side text disappears.
                buffer[i] = 181     // R
                buffer[i + 1] = 226 // G
                buffer[i + 2] = 160 // B
            }
        }

        return ctx.makeImage()
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
