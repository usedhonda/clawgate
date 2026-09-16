import AppKit
import Vision

/// Extracts text from screen regions using Vision framework OCR.
/// Requires Screen Recording permission for CGWindowListCreateImage.
/// Gracefully returns nil when permission is not granted.
enum VisionOCR {
    struct InboundOCRObservation: Equatable {
        let text: String
        /// Top-down global screen Y of the observation's top edge.
        let screenY: CGFloat
    }

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
        var bubbleStatus: String = "unavailable"
        var bubbleCount: Int = 0
        var recognizedPixels: Int = 0
        var cacheHits: Int = 0
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

    /// Recognize only verified incoming bubble interiors, never surrounding labels.
    static func extractTextLineInbound(
        from screenRect: CGRect,
        windowID: CGWindowID = kCGNullWindowID,
        debug: UnsafeMutablePointer<InboundPreprocessDebug>? = nil,
        config: OCRConfig = .default,
        cacheScope: String = ""
    ) -> String? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else {
            return nil
        }
        return performOCRInbound(on: image, debug: debug, config: config, cacheScope: cacheScope)
    }

    /// Atlas observations are mapped back to the original screen coordinates.
    static func extractTextLineInboundPositioned(
        from screenRect: CGRect,
        windowID: CGWindowID = kCGNullWindowID,
        debug: UnsafeMutablePointer<InboundPreprocessDebug>? = nil,
        config: OCRConfig = .default,
        cacheScope: String = ""
    ) -> [InboundOCRObservation]? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else {
            return nil
        }
        return performOCRInboundPositioned(
            on: image,
            screenRect: screenRect,
            debug: debug,
            config: config,
            cacheScope: cacheScope
        )
    }

    /// Converts Vision's bottom-up normalized bounding box into top-down global
    /// screen coordinates. The top edge is used to match positional dedup's
    /// line anchor semantics.
    static func globalTopDownY(for observationBoundingBox: CGRect, in screenRect: CGRect) -> CGFloat {
        screenRect.minY + (1 - observationBoundingBox.maxY) * screenRect.height
    }

    /// Captures the bubble atlas and a selection overlay without invoking OCR.
    static func captureInboundDebugImages(from screenRect: CGRect, windowID: CGWindowID = kCGNullWindowID) -> (raw: CGImage, preprocessed: CGImage?, overlay: CGImage?, status: String, rects: String)? {
        guard let image = captureImage(from: screenRect, windowID: windowID) else { return nil }
        let preview = InboundBubbleOCR.preview(image)
        return (image, preview.image, preview.overlay, preview.status, preview.rects)
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
        config: OCRConfig = .default,
        cacheScope: String = ""
    ) -> String? {
        guard let observations = performOCRInboundObservations(on: image, debug: debug, config: config, cacheScope: cacheScope) else {
            return nil
        }
        return observations.isEmpty ? nil : observations.map(\.text).joined(separator: "\n")
    }

    private static func performOCRInboundPositioned(
        on image: CGImage,
        screenRect: CGRect,
        debug: UnsafeMutablePointer<InboundPreprocessDebug>? = nil,
        config: OCRConfig = .default,
        cacheScope: String = ""
    ) -> [InboundOCRObservation]? {
        guard let observations = performOCRInboundObservations(on: image, debug: debug, config: config, cacheScope: cacheScope) else {
            return nil
        }
        return observations.map { observation in
            return InboundOCRObservation(
                text: observation.text,
                screenY: globalTopDownY(
                    for: observation.boundingBox,
                    in: screenRect
                )
            )
        }
    }

    private struct AcceptedInboundObservation {
        let text: String
        let boundingBox: CGRect
    }

    private static func performOCRInboundObservations(
        on image: CGImage,
        debug: UnsafeMutablePointer<InboundPreprocessDebug>? = nil,
        config: OCRConfig = .default,
        cacheScope: String = ""
    ) -> [AcceptedInboundObservation]? {
        guard let result = InboundBubbleOCR.recognize(image, scope: cacheScope, config: config) else {
            debug?.pointee.bubbleStatus = "uncertain"
            return nil
        }
        debug?.pointee.bubbleStatus = result.bubbleCount == 0 ? "noBubbles" : "ready"
        debug?.pointee.bubbleCount = result.bubbleCount
        debug?.pointee.recognizedPixels = result.recognizedPixels
        debug?.pointee.cacheHits = result.cacheHits
        return result.observations.map { AcceptedInboundObservation(text: $0.text, boundingBox: $0.boundingBox) }
    }

    // MARK: - Chrome rejection

    /// Letters that may remain in a text once its label vocabulary is removed
    /// before it stops counting as chrome and starts counting as a message.
    private static let chromeResidualLetterLimit = 3
    private static let chromeLabelVocabulary = ["午前", "午後", "既読", "AM", "PM", "am", "pm"]

    /// Keep the message body and drop the chrome LINE renders beside it.
    ///
    /// A timestamp and a read receipt are separate OCR observations, never part
    /// of the bubble they belong to, so they can be dropped whole -- a time
    /// written inside a sentence is in the sentence's own observation and is
    /// never seen here.
    ///
    /// Returning nil when nothing but chrome survives is the point of this
    /// function, not a detail: a frame whose only content is a clock is not a
    /// message, and emitting it once produced an appointment nobody made.
    static func inboundBody(fromObservedTexts texts: [String]) -> String? {
        let body = texts.filter { !isChromeLabel($0) }
        guard !body.isEmpty else { return nil }
        return body.joined(separator: "\n")
    }

    /// True when a text is a timestamp or a read receipt rather than a message.
    ///
    /// Matching the rendered wording is not enough. An inbound bubble is white,
    /// so its row never reaches the green mask and its timestamp survives
    /// preprocessing on every single frame; read at fallback confidence it also
    /// garbles, and "午前 10:05" has been observed coming back as "千別 10:0".
    /// So the test is structural: a clock fragment (or a read receipt) carrying
    /// almost no other letters, whether or not the letters it does carry were
    /// recognised correctly.
    static func isChromeLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // Enough real letters to be a sentence: keep it, clock fragment or not.
        guard residualLetterCount(trimmed) < chromeResidualLetterLimit else { return false }
        if trimmed.contains("既読") { return true }
        return containsClockFragment(trimmed)
    }

    /// Letters left once the label vocabulary is stripped. Digits, punctuation
    /// and OCR debris are not letters and never count.
    private static func residualLetterCount(_ text: String) -> Int {
        var stripped = text
        for token in chromeLabelVocabulary {
            stripped = stripped.replacingOccurrences(of: token, with: "")
        }
        return stripped.reduce(into: 0) { count, character in
            if character.isLetter { count += 1 }
        }
    }

    /// H:MM, and the truncated H:M that low-confidence OCR produces from it.
    private static func containsClockFragment(_ text: String) -> Bool {
        let chars = Array(text)
        for (index, character) in chars.enumerated() where character == ":" || character == "：" {
            let digitsBefore = countDigits(in: chars, from: index - 1, step: -1)
            let digitsAfter = countDigits(in: chars, from: index + 1, step: 1)
            if (1...2).contains(digitsBefore), (1...2).contains(digitsAfter) {
                return true
            }
        }
        return false
    }

    private static func countDigits(in chars: [Character], from start: Int, step: Int) -> Int {
        var index = start
        var count = 0
        while index >= 0, index < chars.count, chars[index].isNumber, count < 3 {
            count += 1
            index += step
        }
        return count
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
