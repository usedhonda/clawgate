import AppKit
import Vision

/// Extracts text from screen regions using Vision framework OCR.
/// Requires Screen Recording permission for CGWindowListCreateImage.
/// Gracefully returns nil when permission is not granted.
enum VisionOCR {
    struct OCRConfig {
        var confidenceAccept: Float = 0.40
        var confidenceFallback: Float = 0.25
        var revision: Int = 0             // 0 = OS default
        var usesLanguageCorrection: Bool = true
        var candidateCount: Int = 3
        static let `default` = OCRConfig()
    }

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
    static func extractText(from screenRect: CGRect, windowID: CGWindowID = kCGNullWindowID, config: OCRConfig = .default) -> String? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else {
            return nil
        }
        return performOCR(on: image, config: config)
    }

    /// OCR for LINE inbound text:
    /// runs OCR on the raw image and filters results by bounding-box geometry
    /// to keep only left-aligned (inbound) observations.
    static func extractTextLineInbound(
        from screenRect: CGRect,
        windowID: CGWindowID = kCGNullWindowID,
        debug: UnsafeMutablePointer<InboundPreprocessDebug>? = nil,
        config: OCRConfig = .default
    ) -> String? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else {
            return nil
        }
        return performOCRInbound(on: image, debug: debug, config: config)
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
    static func extractText(from rects: [CGRect], padding: CGFloat = 4, windowID: CGWindowID = kCGNullWindowID, config: OCRConfig = .default) -> String? {
        guard !rects.isEmpty else { return nil }
        let merged = rects.reduce(rects[0]) { $0.union($1) }
        let padded = merged.insetBy(dx: -padding, dy: -padding)
        return extractText(from: padded, windowID: windowID, config: config)
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
        debug: UnsafeMutablePointer<InboundPreprocessDebug>? = nil,
        config: OCRConfig = .default
    ) -> String? {
        let preprocessing = preprocessInboundImage(image)
        debug?.pointee = preprocessing.debug
        let ocrImage = preprocessing.image ?? image

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = config.usesLanguageCorrection

        if config.revision > 0 {
            if #available(macOS 14, *), config.revision >= 3 {
                request.revision = VNRecognizeTextRequestRevision3
            } else if #available(macOS 13, *), config.revision >= 2 {
                request.revision = VNRecognizeTextRequestRevision2
            }
        }

        let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else { return nil }

        let inboundTexts = observations.compactMap { obs -> String? in
            let candidates = obs.topCandidates(config.candidateCount)
            if let accepted = candidates.first(where: { $0.confidence >= config.confidenceAccept }) {
                return accepted.string
            }
            if let best = candidates.first, best.confidence >= config.confidenceFallback {
                return best.string
            }
            return nil
        }
        guard !inboundTexts.isEmpty else { return nil }
        return inboundTexts.joined(separator: "\n")
    }

    // MARK: - Inbound preprocessing (fixed right lane)

    private static let laneOffsetRatio: Double = 0.045  // 4.5% from right edge (anchor crop basis)
    private static let laneHalfWidth = 1  // 3px lane
    private static let greenRowThreshold = 10  // min green pixels in a row for full-width scan
    private static let whiteThreshold = 238
    private static let minBottomWhiteRun = 8
    /// Guard against false cut detection in the middle of chat history.
    /// Input separator is expected near bottom in normal LINE layout.
    private static let minAcceptedCutRatioFromTop = 0.84

    private enum LaneRowClass {
        case white
        case green
        case other
    }

    /// Fixed-lane preprocessing for inbound OCR:
    /// 1) full-width scan classifies rows with green pixels as outbound,
    /// 2) right-offset lane classifies remaining rows as white/other (for yCut),
    /// 3) masks all green rows (no expansion),
    /// 4) drops everything at/below Y cut.
    private static func preprocessInboundImage(_ image: CGImage) -> (image: CGImage?, debug: InboundPreprocessDebug) {
        let width = image.width
        let height = image.height
        let fallbackOffset = max(16, Int(Double(width) * laneOffsetRatio))
        let fallbackDebug = InboundPreprocessDebug(
            laneX: max(0, width - fallbackOffset),
            yCut: nil,
            greenRows: 0,
            expandedGreenRows: 0,
            cutApplied: false,
            frameSkippedNoCut: true
        )
        guard width > (16 + laneHalfWidth), height > 0 else {
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
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (nil, fallbackDebug)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let dynamicOffset = max(16, Int(Double(width) * laneOffsetRatio))
        let laneX = max(laneHalfWidth, min(width - 1 - laneHalfWidth, width - dynamicOffset))
        let laneRange = (laneX - laneHalfWidth)...(laneX + laneHalfWidth)
        let voteThreshold = laneRange.count / 2 + 1

        var rowClasses = [LaneRowClass](repeating: .other, count: height)
        var greenRows = 0
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            var greenCount = 0
            for x in 0..<width {
                let i = rowOffset + x * 4
                let r = Int(buffer[i])
                let g = Int(buffer[i + 1])
                let b = Int(buffer[i + 2])
                if isOutgoingGreenPixel(r: r, g: g, b: b) {
                    greenCount += 1
                    if greenCount >= greenRowThreshold { break }
                }
            }

            if greenCount >= greenRowThreshold {
                rowClasses[y] = .green
                greenRows += 1
            } else {
                // White row detection stays lane-based (for yCut)
                var whiteVotes = 0
                for x in laneRange {
                    let i = rowOffset + x * 4
                    let r = Int(buffer[i])
                    let g = Int(buffer[i + 1])
                    let b = Int(buffer[i + 2])
                    if isNearWhitePixel(r: r, g: g, b: b) { whiteVotes += 1 }
                }
                rowClasses[y] = whiteVotes >= voteThreshold ? .white : .other
            }
        }

        let yCut = findBottomCutY(rowClasses: rowClasses)

        var changed = false
        for y in 0..<height {
            let shouldWhiteRow = rowClasses[y] == .green || {
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
                expandedGreenRows: greenRows,
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
        let minAcceptedCutY = Int(Double(height) * minAcceptedCutRatioFromTop)

        var run = 0
        var runStart: Int?
        for y in stride(from: height - 1, through: searchStart, by: -1) {
            if rowClasses[y] == .white {
                run += 1
                runStart = y
            } else {
                if run >= minRun, let start = runStart {
                    return start >= minAcceptedCutY ? start : nil
                }
                run = 0
                runStart = nil
            }
        }
        if run >= minRun, let start = runStart {
            return start >= minAcceptedCutY ? start : nil
        }
        return nil
    }

    private static func isOutgoingGreenPixel(r: Int, g: Int, b: Int) -> Bool {
        g > 130 && g > r + 10 && g > b + 16
    }

    private static func isNearWhitePixel(r: Int, g: Int, b: Int) -> Bool {
        r >= whiteThreshold && g >= whiteThreshold && b >= whiteThreshold
    }

    private static func performOCR(on image: CGImage, config: OCRConfig = .default) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = config.usesLanguageCorrection

        if config.revision > 0 {
            if #available(macOS 14, *), config.revision >= 3 {
                request.revision = VNRecognizeTextRequestRevision3
            } else if #available(macOS 13, *), config.revision >= 2 {
                request.revision = VNRecognizeTextRequestRevision2
            }
        }

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
            let candidates = observation.topCandidates(config.candidateCount)
            if let accepted = candidates.first(where: { $0.confidence >= config.confidenceAccept }) {
                return accepted.string
            }
            if let best = candidates.first, best.confidence >= config.confidenceFallback {
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
