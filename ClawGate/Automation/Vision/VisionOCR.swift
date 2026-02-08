import AppKit
import Vision

/// Extracts text from screen regions using Vision framework OCR.
/// Requires Screen Recording permission for CGWindowListCreateImage.
/// Gracefully returns nil when permission is not granted.
enum VisionOCR {

    /// Extract text from a screen rectangle (in global CG coordinates).
    /// Returns nil if Screen Recording permission is missing or OCR fails.
    /// NOTE: Uses optionOnScreenOnly — LINE window must be visible (not occluded).
    static func extractText(from screenRect: CGRect) -> String? {
        guard let image = CGWindowListCreateImage(
            screenRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return nil
        }

        // Zero-size image means Screen Recording permission is likely missing
        if image.width == 0 || image.height == 0 {
            return nil
        }

        return performOCR(on: image)
    }

    /// Extract text from multiple screen rectangles merged into one capture (with padding).
    /// More efficient than calling extractText(from:) per-rect: N rects × 300ms → 1 capture × 300ms.
    static func extractText(from rects: [CGRect], padding: CGFloat = 4) -> String? {
        guard !rects.isEmpty else { return nil }
        let merged = rects.reduce(rects[0]) { $0.union($1) }
        let padded = merged.insetBy(dx: -padding, dy: -padding)
        return extractText(from: padded)
    }

    // MARK: - Private

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

        let texts = observations.compactMap { $0.topCandidates(1).first?.string }
        guard !texts.isEmpty else {
            return nil
        }

        return texts.joined(separator: "\n")
    }
}
