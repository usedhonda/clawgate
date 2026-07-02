import Foundation

/// Pure formatting helpers that turn an `OpsLogEntry` into a compact,
/// human-readable one-line summary for the menu-bar log view.
///
/// Extracted verbatim from `MenuBarApp` so the parsing/formatting logic can be
/// unit-tested in isolation from AppKit. Behavior is unchanged: the only edits
/// are `private func` -> `static func` and moving the type here.
enum OpsLogSummarizer {
    struct ParsedMessageFields {
        let project: String?
        let bytes: Int?
        let text: String
    }

    static func humanReadableSummary(for entry: OpsLogEntry) -> String {
        let fields = parseMessageFields(entry.message)
        let project = shortProject(fields.project)
        let bytes = fields.bytes.map { "\($0)b" } ?? "-b"
        let preview = compactMessage(fields.text, max: 32)

        switch entry.event {
        case "federation.connected":
            return "FED UP \(compactMessage(entry.message, max: 32))"
        case "federation.connecting":
            return "FED CONNECT \(compactMessage(entry.message, max: 28))"
        case "federation.closed":
            return "FED CLOSED \(compactMessage(entry.message, max: 24))"
        case "federation.receive_failed", "federation.send_failed", "federation.error":
            return "FED ERR \(compactMessage(entry.message, max: 28))"
        case "federation.disabled", "federation.invalid_url":
            return "FED OFF \(compactMessage(entry.message, max: 28))"
        case "tmux.completion":
            return "CAP DONE \(project) \(bytes) \(preview)"
        case "tmux.question":
            return "CAP Q \(project) \(bytes) \(preview)"
        case "tmux.progress":
            return "CAP PROG \(project) \(bytes) \(preview)"
        case "tmux.forward":
            return "FWD \(project) \(bytes) \(preview)"
        case "tmux_gateway_deliver":
            return "ACK \(project)"
        case "line_send_ok":
            return "MSG OUT OK"
        case "line_send_start":
            return "MSG SEND"
        case "send_failed":
            let parts = parseKeyValueMessage(entry.message)
            let code = parts["error_code"] ?? "unknown"
            let msg = compactMessage(parts["error_message"] ?? "", max: 32)
            return "ERR \(project) \(code) \(msg)"
        case "ingress_received":
            return "SRV IN"
        case "ingress_validated":
            return "SRV VALID"
        default:
            let fallback = compactMessage(entry.message, max: 40)
            if fallback.isEmpty {
                return entry.event
            }
            return "\(entry.event) \(fallback)"
        }
    }

    static func parseMessageFields(_ message: String) -> ParsedMessageFields {
        let kv = parseKeyValueMessage(message)
        let project = kv["project"]
        let bytes = kv["bytes"].flatMap(Int.init)

        let text: String
        if let range = message.range(of: "text=") {
            text = String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = ""
        }
        return ParsedMessageFields(project: project, bytes: bytes, text: text)
    }

    static func parseKeyValueMessage(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        let tokens = message.split(separator: " ")
        for token in tokens {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
            if !key.isEmpty && !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    static func shortProject(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "-" }
        return String(trimmed.prefix(16))
    }

    private static func compactMessage(_ text: String, max: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        if single.count <= max { return single }
        return String(single.prefix(max)) + "..."
    }
}
