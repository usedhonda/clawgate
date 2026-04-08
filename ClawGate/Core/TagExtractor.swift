import Foundation

/// Extracts structured tags from AI responses.
enum TagExtractor {
    /// Extract text from `<draft_reply>...</draft_reply>` tags.
    /// Returns the draft text content, or nil if no tag found or empty.
    static func extractDraftReply(from text: String) -> String? {
        let pattern = #"<draft_reply>\s*([\s\S]*?)\s*</draft_reply>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let draft = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? nil : draft
    }
}
