import Foundation

/// One line per Gateway socket that closed, written by the client that owned it.
///
/// The Gateway logs closes too, but under one device id for both of this Mac's
/// sockets, so its rows cannot be attributed to the Pet socket or the ambient
/// ingest socket. Measured 2026-09-22: 72% of a day's gaps between consecutive
/// closes came out negative, because two interleaved lifetimes were being read
/// as one chain. Durations per role are therefore recorded here, where the role
/// is known for certain, and the Gateway's totals stay as the cross-check.
///
/// Append-only, one file per local day, in the idiom of `ReminderTraceStore`.
enum WSCloseLog {
    struct Entry: Codable, Equatable {
        let role: String
        let pid: Int32
        /// nil when the socket never finished connecting — a failed attempt is
        /// worth a line too, and its duration is then the time spent trying.
        let connectedAt: Date?
        let closedAt: Date
        let durationSeconds: Double?
        /// The code on the task before this side cancelled: 1006 means it was
        /// already gone, 1001 means an intentional close. See
        /// `OpenClawWSClient.lastObservedCloseCode`.
        let observedCloseCode: Int?
        let connectAttempts: Int
        let generation: UInt64
    }

    static var root: URL {
        AmbientStorage.ambientRoot.appendingPathComponent("ws", isDirectory: true)
    }

    /// Never throws out: a failure to record must not affect the teardown that
    /// is calling this.
    static func append(_ entry: Entry, root: URL = WSCloseLog.root) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = root.appendingPathComponent("closes-\(dayString(entry.closedAt)).jsonl",
                                              isDirectory: false)
        let bytes = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(bytes)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: bytes)
        }
    }

    /// Today's and yesterday's entries, oldest first, for `/v1/debug/ws-closes`.
    /// A line that cannot be decoded is skipped rather than failing the read.
    static func recent(now: Date = Date(), root: URL = WSCloseLog.root) -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Entry] = []
        for day in [now.addingTimeInterval(-86_400), now] {
            let url = root.appendingPathComponent("closes-\(dayString(day)).jsonl",
                                                  isDirectory: false)
            guard let data = FileManager.default.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(Entry.self, from: lineData) else { continue }
                out.append(entry)
            }
        }
        return out.sorted { $0.closedAt < $1.closedAt }
    }

    private static func dayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = .current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}
