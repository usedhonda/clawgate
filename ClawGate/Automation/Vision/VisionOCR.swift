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
    /// runs OCR on the raw image and filters results by bounding-box geometry
    /// to keep only left-aligned (inbound) observations.
    static func extractTextLineInbound(from screenRect: CGRect, windowID: CGWindowID = kCGNullWindowID) -> String? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else {
            return nil
        }
        return performOCRInbound(on: image)
    }

    /// Capture raw + preprocessed images for inbound OCR debugging.
    /// Returns nil when capture failed (e.g. Screen Recording permission missing).
    /// Preprocessing is now a no-op; preprocessed is identical to raw.
    static func captureInboundDebugImages(from screenRect: CGRect, windowID: CGWindowID = kCGNullWindowID) -> (raw: CGImage, preprocessed: CGImage?)? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else {
            return nil
        }
        return (raw: image, preprocessed: image)
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

    /// OCR for inbound text with outgoing (green bubble) rows masked out.
    /// Before OCR, scans the right edge of the image for green-tinted pixels
    /// (LINE outgoing bubbles) and whites out those rows entirely.
    /// This eliminates outgoing text at the pixel level, making bounding-box
    /// filtering unnecessary.
    private static func performOCRInbound(on image: CGImage) -> String? {
        let ocrImage = maskOutgoingRows(in: image) ?? image

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else { return nil }

        let inboundTexts = observations.compactMap { obs -> String? in
            let candidates = obs.topCandidates(3)
            if let accepted = candidates.first(where: { $0.confidence >= 0.40 }) {
                return accepted.string
            }
            if let best = candidates.first, best.confidence >= 0.25 {
                return best.string
            }
            return nil
        }
        guard !inboundTexts.isEmpty else { return nil }
        return inboundTexts.joined(separator: "\n")
    }

    /// Mask outgoing (green bubble) rows by scanning the right edge column.
    /// LINE outgoing bubbles are right-aligned, so a single pixel column near
    /// the right edge reliably detects them. Detected rows are overwritten
    /// with white pixels in-place before returning a new CGImage.
    private static func maskOutgoingRows(in image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 32, height > 0 else { return nil }

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

        // Sample column near the right edge (offset inward to avoid border artifacts)
        let sampleX = width - 16

        // Scan bottom-to-top; CGContext has origin at top-left after draw
        var maskedCount = 0
        for y in stride(from: height - 1, through: 0, by: -1) {
            let offset = y * bytesPerRow + sampleX * 4
            let r = buffer[offset]
            let g = buffer[offset + 1]
            let b = buffer[offset + 2]

            // Same threshold as looksOutgoingBubbleColor:
            // g > 118 && g > r + 10 && g > b + 16
            if g > 118, g > r &+ 10, g > b &+ 16 {
                // White out the entire row (RGBA = 255,255,255,255)
                let rowStart = y * bytesPerRow
                for i in stride(from: rowStart, to: rowStart + bytesPerRow, by: 1) {
                    buffer[i] = 255
                }
                maskedCount += 1
            }
        }

        // No rows masked — return nil to use original image (avoids CGImage creation cost)
        guard maskedCount > 0 else { return nil }

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
            if let accepted = candidates.first(where: { $0.confidence >= 0.40 }) {
                return accepted.string
            }
            // Keep best candidate as fallback only when confidence is reasonable.
            if let best = candidates.first, best.confidence >= 0.25 {
                return best.string
            }
            return nil
        }
        guard !texts.isEmpty else {
            return nil
        }

        return texts.joined(separator: "\n")
    }
}
