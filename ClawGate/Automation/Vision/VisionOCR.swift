import AppKit
import Vision

/// Extracts text from screen regions using Vision framework OCR.
/// Requires Screen Recording permission for CGWindowListCreateImage.
/// Gracefully returns nil when permission is not granted.
enum VisionOCR {
    struct InboundPreprocessDebug {
        var laneX: Int
        var yCut: Int?
        var greenRows: Int
        var expandedGreenRows: Int
        var cutApplied: Bool
        var frameSkippedNoCut: Bool
    }

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
    static func extractTextLineInbound(
        from screenRect: CGRect,
        windowID: CGWindowID = kCGNullWindowID,
        debug: UnsafeMutablePointer<InboundPreprocessDebug>? = nil
    ) -> String? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else {
            return nil
        }
        return performOCRInbound(on: image, debug: debug)
    }

    /// Capture raw + preprocessed images for inbound OCR debugging.
    /// Returns nil when capture failed (e.g. Screen Recording permission missing).
    /// Preprocessed image reflects fixed-lane outbound masking and bottom cut.
    static func captureInboundDebugImages(from screenRect: CGRect, windowID: CGWindowID = kCGNullWindowID) -> (raw: CGImage, preprocessed: CGImage?)? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else {
            return nil
        }
        let preprocessed = preprocessInboundImage(image)
        return (raw: image, preprocessed: preprocessed.image)
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

    private static func performOCRInbound(
        on image: CGImage,
        debug: UnsafeMutablePointer<InboundPreprocessDebug>? = nil
    ) -> String? {
        let preprocessing = preprocessInboundImage(image)
        debug?.pointee = preprocessing.debug
        let ocrImage = preprocessing.image ?? image

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

    // MARK: - Inbound preprocessing (fixed right lane)

    private static let laneOffsetFromRight = 38
    private static let laneHalfWidth = 1  // 3px lane
    private static let greenExpandRows = 3
    private static let whiteThreshold = 238
    private static let minBottomWhiteRun = 8

    private enum LaneRowClass {
        case white
        case green
        case other
    }

    /// Fixed-lane preprocessing for inbound OCR:
    /// 1) uses right-offset lane to classify rows (white/green/other),
    /// 2) finds bottom white run as Y cut,
    /// 3) masks all green rows (+/- expand),
    /// 4) drops everything at/below Y cut.
    private static func preprocessInboundImage(_ image: CGImage) -> (image: CGImage?, debug: InboundPreprocessDebug) {
        let width = image.width
        let height = image.height
        let fallbackDebug = InboundPreprocessDebug(
            laneX: max(0, width - laneOffsetFromRight),
            yCut: nil,
            greenRows: 0,
            expandedGreenRows: 0,
            cutApplied: false,
            frameSkippedNoCut: true
        )
        guard width > (laneOffsetFromRight + laneHalfWidth), height > 0 else {
            return (nil, fallbackDebug)
        }

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
            return (nil, fallbackDebug)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let laneX = max(laneHalfWidth, min(width - 1 - laneHalfWidth, width - laneOffsetFromRight))
        let laneRange = (laneX - laneHalfWidth)...(laneX + laneHalfWidth)
        let voteThreshold = laneRange.count / 2 + 1

        var rowClasses = [LaneRowClass](repeating: .other, count: height)
        var greenRows = 0
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            var greenVotes = 0
            var whiteVotes = 0
            for x in laneRange {
                let i = rowOffset + x * 4
                let r = Int(buffer[i])
                let g = Int(buffer[i + 1])
                let b = Int(buffer[i + 2])
                if isOutgoingGreenPixel(r: r, g: g, b: b) {
                    greenVotes += 1
                } else if isNearWhitePixel(r: r, g: g, b: b) {
                    whiteVotes += 1
                }
            }

            if greenVotes >= voteThreshold {
                rowClasses[y] = .green
                greenRows += 1
            } else if whiteVotes >= voteThreshold {
                rowClasses[y] = .white
            } else {
                rowClasses[y] = .other
            }
        }

        let yCut = findBottomCutY(rowClasses: rowClasses)

        var expandedMask = [Bool](repeating: false, count: height)
        if greenRows > 0 {
            for y in 0..<height where rowClasses[y] == .green {
                let start = max(0, y - greenExpandRows)
                let end = min(height - 1, y + greenExpandRows)
                for yy in start...end {
                    expandedMask[yy] = true
                }
            }
        }
        let expandedGreenRows = expandedMask.reduce(0) { $0 + ($1 ? 1 : 0) }

        var changed = false
        for y in 0..<height {
            let shouldWhiteRow = expandedMask[y] || {
                guard let cutY = yCut else { return false }
                return y >= cutY
            }()
            if !shouldWhiteRow { continue }
            let rowStart = y * bytesPerRow
            for i in rowStart..<(rowStart + bytesPerRow) {
                buffer[i] = 255
            }
            changed = true
        }

        let processedImage = changed ? ctx.makeImage() : image

        return (
            processedImage,
            InboundPreprocessDebug(
                laneX: laneX,
                yCut: yCut,
                greenRows: greenRows,
                expandedGreenRows: expandedGreenRows,
                cutApplied: yCut != nil,
                frameSkippedNoCut: yCut == nil
            )
        )
    }

    private static func findBottomCutY(rowClasses: [LaneRowClass]) -> Int? {
        let height = rowClasses.count
        guard height > 0 else { return nil }

        let searchStart = max(0, Int(Double(height) * 0.55))
        let minRun = max(minBottomWhiteRun, height / 120)

        var run = 0
        var runStart: Int?
        for y in stride(from: height - 1, through: searchStart, by: -1) {
            if rowClasses[y] == .white {
                run += 1
                runStart = y
            } else {
                if run >= minRun, let start = runStart {
                    return start
                }
                run = 0
                runStart = nil
            }
        }
        if run >= minRun, let start = runStart {
            return start
        }
        return nil
    }

    private static func isOutgoingGreenPixel(r: Int, g: Int, b: Int) -> Bool {
        g > 130 && g > r + 8 && g > b + 12
    }

    private static func isNearWhitePixel(r: Int, g: Int, b: Int) -> Bool {
        r >= whiteThreshold && g >= whiteThreshold && b >= whiteThreshold
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
