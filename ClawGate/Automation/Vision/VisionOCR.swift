import AppKit
import Vision

/// Extracts text from screen regions using Vision framework OCR.
/// Requires Screen Recording permission for CGWindowListCreateImage.
/// Gracefully returns nil when permission is not granted.
enum VisionOCR {

    /// Extract text from a screen rectangle (in global CG coordinates).
    /// Returns nil if Screen Recording permission is missing or OCR fails.
    static func extractText(from screenRect: CGRect) -> String? {
        // CGWindowListCreateImage uses CG coordinates (top-left origin, same as AX frames)
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
