import Foundation

final class ClawGateActualLogger {
    static let shared = ClawGateActualLogger()

    private struct Entry: Codable {
        let timestamp: String
        let channel: String
        let conversation: String
        let textHead: String
        let traceID: String
        let status: String
        let durationMs: Int
        let host: String

        enum CodingKeys: String, CodingKey {
            case timestamp
            case channel
            case conversation
            case textHead = "text_head"
            case traceID = "trace_id"
            case status
            case durationMs = "duration_ms"
            case host
        }
    }

    private let queue = DispatchQueue(label: "com.clawgate.actual-delivery-log", qos: .utility)
    private let encoder: JSONEncoder
    private let isoFormatter: ISO8601DateFormatter
    private let dateFormatter: DateFormatter

    private init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder

        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        self.isoFormatter = iso

        let date = DateFormatter()
        date.calendar = Calendar(identifier: .gregorian)
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = date
    }

    func append(
        channel: String,
        conversation: String,
        text: String,
        traceID: String,
        durationMs: Int,
        logger: AppLogger
    ) {
        let entry = Entry(
            timestamp: isoFormatter.string(from: Date()),
            channel: channel,
            conversation: conversation,
            textHead: Self.textHead(text),
            traceID: traceID,
            status: "sent",
            durationMs: durationMs,
            host: Self.hostLabel()
        )

        queue.async { [encoder, dateFormatter] in
            do {
                let logsDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".openclaw", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

                let day = dateFormatter.string(from: Date())
                let fileURL = logsDir.appendingPathComponent("clawgate-actual-\(day).jsonl")
                var data = try encoder.encode(entry)
                data.append(0x0A)

                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: fileURL, options: [.atomic])
                }
            } catch {
                logger.log(.warning, "Failed to write clawgate-actual JSONL: \(error)")
            }
        }
    }

    private static func textHead(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard normalized.count > 60 else { return normalized }
        return "\(normalized.prefix(60))..."
    }

    private static func hostLabel() -> String {
        let raw = [
            Host.current().localizedName,
            Host.current().name
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        if raw.contains("macmini") || raw.contains("mac-mini") || raw.contains("mini") {
            return "macmini"
        }
        return "hostB"
    }
}
