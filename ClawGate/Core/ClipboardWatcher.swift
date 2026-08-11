import AppKit
import Foundation

/// Monitors NSPasteboard for changes and classifies clipboard content.
/// Event-driven via changeCount polling (lightweight, ~1ms per check).
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    var onOffer: ((ClipboardOffer) -> Void)?

    private let stateLock = NSLock()
    private var lastChangeCount: Int = 0
    private var timer: Timer?
    private var ownedChangeCount: Int?

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        timer?.invalidate()
        stateLock.lock()
        lastChangeCount = NSPasteboard.general.changeCount
        ownedChangeCount = nil
        stateLock.unlock()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stateLock.lock()
        ownedChangeCount = nil
        lastChangeCount = NSPasteboard.general.changeCount
        stateLock.unlock()
    }

    /// Mutate the pasteboard and register its final change count as one atomic
    /// watcher transaction. Timer checks cannot observe the mutation halfway.
    @discardableResult
    func performOwnedMutation(
        on pasteboard: NSPasteboard = .general,
        _ mutation: () -> Void
    ) -> Int {
        stateLock.lock()
        mutation()
        let changeCount = pasteboard.changeCount
        ownedChangeCount = changeCount
        stateLock.unlock()
        return changeCount
    }

    /// Write one owned string without exposing mutation details to callers.
    @discardableResult
    func writeOwnedString(
        _ text: String,
        to pasteboard: NSPasteboard = .general
    ) -> Int {
        performOwnedMutation(on: pasteboard) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    /// Restore only while the expected owned transaction is still current.
    /// The check and restore are serialized with the watcher and registration.
    @discardableResult
    func performOwnedMutationIfCurrentChangeCount(
        _ expectedChangeCount: Int,
        on pasteboard: NSPasteboard = .general,
        _ mutation: () -> Void
    ) -> Int? {
        stateLock.lock()
        guard pasteboard.changeCount == expectedChangeCount else {
            stateLock.unlock()
            return nil
        }
        mutation()
        let changeCount = pasteboard.changeCount
        ownedChangeCount = changeCount
        stateLock.unlock()
        return changeCount
    }

    /// Read the pasteboard change count and its ownership marker under the
    /// same lock used by app-owned mutations. This prevents another watcher
    /// from observing a half-finished clear/write transaction.
    func ownershipSnapshot(
        on pasteboard: NSPasteboard = .general
    ) -> (changeCount: Int, isOwned: Bool) {
        stateLock.lock()
        let changeCount = pasteboard.changeCount
        let isOwned = ownedChangeCount == changeCount
        stateLock.unlock()
        return (changeCount, isOwned)
    }

    private func check() {
        let pb = NSPasteboard.general
        let text: String?
        let handler: ((ClipboardOffer) -> Void)?

        stateLock.lock()
        let current = pb.changeCount
        guard current != lastChangeCount else {
            stateLock.unlock()
            return
        }
        lastChangeCount = current

        if ownedChangeCount == current {
            stateLock.unlock()
            return
        }
        ownedChangeCount = nil
        text = pb.string(forType: .string)
        handler = onOffer
        stateLock.unlock()

        guard let text, !text.isEmpty else { return }

        // Skip very short or very long
        guard text.count >= 3, text.count <= 50_000 else { return }

        // Classify and offer
        if let offer = ClipboardClassifier.classify(text: text) {
            handler?(offer)
        }
    }

    #if DEBUG
    func checkForTesting() {
        check()
    }
    #endif
}

// MARK: - Offer Model

struct ClipboardOffer {
    let text: String
    let contentType: ClipboardContentType
    let actions: [ClipboardAction]
    let sourceApp: String?  // filled in by PetModel from lastTrackedApp
}

enum ClipboardContentType: String {
    case json
    case url
    case error
    case code
    case english
    case japanese
    case longText
    case base64
    case jwt
    case terminalOutput  // indented/decorated terminal text
}

struct ClipboardAction {
    let label: String           // e.g., "Format JSON"
    let type: ClipboardActionType
}

enum ClipboardActionType {
    // Local actions (no Gateway needed)
    case formatJSON
    case stripIndent
    case joinLines
    case decodeBase64
    case decodeJWT
    case copyClean(String)  // replace clipboard with cleaned text

    // Gateway actions
    case translate(to: String)  // "ja" or "en"
    case explain
    case summarize
    case draftReply
    case review
}

// MARK: - Classifier

enum ClipboardClassifier {

    static func classify(text: String) -> ClipboardOffer? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Skip password-like strings (high entropy, short)
        if trimmed.count < 40, looksLikeSecret(trimmed) { return nil }

        // Skip file paths
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            if !trimmed.contains("\n") { return nil }
        }

        // Order matters — most specific first

        // JWT
        if trimmed.hasPrefix("eyJ"), trimmed.filter({ $0 == "." }).count == 2 {
            return ClipboardOffer(text: text, contentType: .jwt, actions: [
                ClipboardAction(label: "Decode JWT", type: .decodeJWT),
            ], sourceApp: nil)
        }

        // JSON
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) {
            if let _ = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
                return ClipboardOffer(text: text, contentType: .json, actions: [
                    ClipboardAction(label: "Format JSON", type: .formatJSON),
                    ClipboardAction(label: "Explain structure", type: .explain),
                ], sourceApp: nil)
            }
        }

        // URL
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            if !trimmed.contains("\n"), URL(string: trimmed) != nil {
                return ClipboardOffer(text: text, contentType: .url, actions: [
                    ClipboardAction(label: "Summarize page", type: .summarize),
                ], sourceApp: nil)
            }
        }

        // Error / stack trace
        if looksLikeError(trimmed) {
            return ClipboardOffer(text: text, contentType: .error, actions: [
                ClipboardAction(label: "Explain error", type: .explain),
            ], sourceApp: nil)
        }

        // Terminal output with common indent (Claude Code style)
        if looksLikeTerminalIndented(trimmed) {
            return ClipboardOffer(text: text, contentType: .terminalOutput, actions: [
                ClipboardAction(label: "Strip indent", type: .stripIndent),
                ClipboardAction(label: "Join lines", type: .joinLines),
            ], sourceApp: nil)
        }

        // Code
        if looksLikeCode(trimmed) {
            return ClipboardOffer(text: text, contentType: .code, actions: [
                ClipboardAction(label: "Explain code", type: .explain),
                ClipboardAction(label: "Review", type: .review),
            ], sourceApp: nil)
        }

        // Base64
        if trimmed.count >= 20, looksLikeBase64(trimmed) {
            return ClipboardOffer(text: text, contentType: .base64, actions: [
                ClipboardAction(label: "Decode Base64", type: .decodeBase64),
            ], sourceApp: nil)
        }

        // English text (> 20 chars, mostly ASCII)
        let asciiRatio = Double(trimmed.unicodeScalars.filter { $0.isASCII }.count) / Double(trimmed.count)
        if trimmed.count > 30, asciiRatio > 0.85, trimmed.contains(" ") {
            return ClipboardOffer(text: text, contentType: .english, actions: [
                ClipboardAction(label: "Translate to Japanese", type: .translate(to: "ja")),
                trimmed.count > 200
                    ? ClipboardAction(label: "Summarize", type: .summarize)
                    : nil,
            ].compactMap { $0 }, sourceApp: nil)
        }

        // Japanese text
        let jpRatio = Double(trimmed.unicodeScalars.filter { $0.value >= 0x3000 && $0.value <= 0x9FFF }.count) / max(1, Double(trimmed.count))
        if trimmed.count > 20, jpRatio > 0.15 {
            return ClipboardOffer(text: text, contentType: .japanese, actions: [
                ClipboardAction(label: "Translate to English", type: .translate(to: "en")),
                trimmed.count > 200
                    ? ClipboardAction(label: "Summarize", type: .summarize)
                    : nil,
            ].compactMap { $0 }, sourceApp: nil)
        }

        // Long text (generic)
        if trimmed.count > 200 {
            return ClipboardOffer(text: text, contentType: .longText, actions: [
                ClipboardAction(label: "Summarize", type: .summarize),
            ], sourceApp: nil)
        }

        return nil  // Nothing useful to offer
    }

    // MARK: - Heuristics

    private static func looksLikeSecret(_ s: String) -> Bool {
        // High entropy, no spaces, mixed case + digits + symbols
        guard !s.contains(" ") else { return false }
        let hasUpper = s.contains(where: { $0.isUppercase })
        let hasLower = s.contains(where: { $0.isLowercase })
        let hasDigit = s.contains(where: { $0.isNumber })
        let hasSymbol = s.contains(where: { !$0.isLetter && !$0.isNumber })
        let mixCount = [hasUpper, hasLower, hasDigit, hasSymbol].filter { $0 }.count
        return mixCount >= 3
    }

    private static func looksLikeError(_ s: String) -> Bool {
        let lower = s.lowercased()
        let errorKeywords = ["error", "exception", "fatal", "panic", "traceback",
                             "stack trace", "at line", "failed", "segfault", "abort"]
        return errorKeywords.contains(where: { lower.contains($0) })
    }

    private static func looksLikeCode(_ s: String) -> Bool {
        let codePatterns = ["func ", "def ", "class ", "import ", "const ", "let ", "var ",
                           "return ", "if (", "if let", "guard ", "switch ", "for (", "while (",
                           "public ", "private ", "static ", "async ", "await "]
        let lines = s.components(separatedBy: .newlines)
        let matchCount = codePatterns.filter { s.contains($0) }.count
        let hasSemicolons = lines.filter { $0.hasSuffix(";") }.count > 1
        let hasBraces = s.contains("{") && s.contains("}")
        return matchCount >= 2 || (hasSemicolons && hasBraces)
    }

    private static func looksLikeTerminalIndented(_ s: String) -> Bool {
        let lines = s.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }
        // Check if most lines have common leading whitespace
        let indentedLines = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
        return Double(indentedLines.count) / Double(lines.count) > 0.6
    }

    private static func looksLikeBase64(_ s: String) -> Bool {
        let stripped = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.contains(" "), !stripped.contains("\n") else { return false }
        let base64Chars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/="))
        return stripped.unicodeScalars.allSatisfy { base64Chars.contains($0) }
    }
}

// MARK: - Local Executors

enum ClipboardExecutor {

    /// Execute a local action and return the result (or nil if Gateway needed)
    static func executeLocal(_ action: ClipboardActionType, text: String) -> String? {
        switch action {
        case .formatJSON:
            return formatJSON(text)
        case .stripIndent:
            return stripCommonIndent(text)
        case .joinLines:
            return joinLines(text)
        case .decodeBase64:
            return decodeBase64(text)
        case .decodeJWT:
            return decodeJWT(text)
        case .copyClean(let cleaned):
            return cleaned
        default:
            return nil  // Needs Gateway
        }
    }

    private static func formatJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8) else { return nil }
        return result
    }

    private static func stripCommonIndent(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmptyLines.isEmpty else { return text }

        // Find minimum leading whitespace
        let minIndent = nonEmptyLines.map { line -> Int in
            line.prefix(while: { $0 == " " || $0 == "\t" }).count
        }.min() ?? 0

        guard minIndent > 0 else { return text }

        return lines.map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
            return String(line.dropFirst(min(minIndent, line.count)))
        }.joined(separator: "\n")
    }

    private static func joinLines(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func decodeBase64(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        return decoded
    }

    private static func decodeJWT(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count >= 2 else { return nil }

        func decodeSegment(_ segment: Substring) -> String? {
            var base64 = String(segment)
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let remainder = base64.count % 4
            if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
            guard let data = Data(base64Encoded: base64),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                  let str = String(data: pretty, encoding: .utf8) else { return nil }
            return str
        }

        var result = ""
        if let header = decodeSegment(parts[0]) {
            result += "Header:\n\(header)\n\n"
        }
        if let payload = decodeSegment(parts[1]) {
            result += "Payload:\n\(payload)"
        }
        return result.isEmpty ? nil : result
    }
}
