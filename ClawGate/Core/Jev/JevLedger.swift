import Foundation

/// One window of Jev usage, as it is appended to a day's tag file.
struct JevTagEntry: Codable, Equatable {
    struct Usage: Codable, Equatable {
        var inputTokens: Int
        var outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    var key: String
    var segmentIds: [String]
    var questionVersion: Int
    var answers: [String: Double]
    var invalid: [String]
    var usage: Usage
    var latencyMs: Int
    var at: Date
}

struct JevDailyTotals: Equatable {
    var calls: Int
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
}

/// A daily, append-only JSONL ledger of every window sent to Jev.
///
/// One line per asked window doubles as the "asked once" dedupe (`hasAsked`):
/// there is no separate index, because a day's file is small enough that
/// reading it whole on every check is simpler than keeping the two in sync.
struct JevLedger {
    var root: URL

    init(root: URL = AmbientStorage.ambientRoot.appendingPathComponent("jev", isDirectory: true)) {
        self.root = root
    }

    static func costUSD(inputTokens: Int) -> Double {
        Double(inputTokens) * 0.042 / 1_000_000
    }

    /// Appends one JSON line for the entry's day (the Mac's current calendar,
    /// matching when the window was actually asked, not UTC).
    func record(_ entry: JevTagEntry) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let line = try? encode(entry) else { return }
        let url = fileURL(for: entry.at)
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data)
        }
    }

    func hasAsked(key: String, on day: Date) -> Bool {
        entries(on: day).contains { $0.key == key }
    }

    func daily(on day: Date) -> JevDailyTotals {
        let rows = entries(on: day)
        let inputTokens = rows.reduce(0) { $0 + $1.usage.inputTokens }
        let outputTokens = rows.reduce(0) { $0 + $1.usage.outputTokens }
        return JevDailyTotals(calls: rows.count, inputTokens: inputTokens, outputTokens: outputTokens,
                              costUSD: Self.costUSD(inputTokens: inputTokens))
    }

    private func fileURL(for date: Date) -> URL {
        root.appendingPathComponent("tags-\(Self.dayString(date)).jsonl", isDirectory: false)
    }

    private static func dayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = .current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private func entries(on day: Date) -> [JevTagEntry] {
        let url = fileURL(for: day)
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [JevTagEntry] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(JevTagEntry.self, from: lineData) else { continue }
            out.append(entry)
        }
        return out
    }

    private func encode(_ entry: JevTagEntry) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        guard let line = String(data: data, encoding: .utf8) else { throw JevError.unexpected }
        return line
    }
}
