import Foundation

/// Append-only on-disk mirror of every `ReminderTrace`, so a reminder that
/// never sounded — or a trace lost from `ReminderReadoutService`'s in-memory
/// ring buffer for any reason — still leaves evidence to diagnose after the
/// fact. One JSON line per day file, in the idiom of `JevLedger`: nothing is
/// ever rewritten in place, and a later line for the same `(reminderId, at)`
/// is simply read as the newer state.
enum ReminderTraceStore {
    /// Default root, injectable so tests never touch the real Application
    /// Support tree.
    static var root: URL {
        AmbientStorage.ambientRoot.appendingPathComponent("reminders", isDirectory: true)
    }

    /// Appends one JSON line for the trace's own day (local calendar,
    /// matching when the reminder was actually handled — not UTC, and not
    /// necessarily "now" for an update written well after midnight). Never
    /// throws out: a write failure here must never affect the readout path
    /// that calls this.
    static func append(_ trace: ReminderTrace, root: URL = ReminderTraceStore.root) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let line = try? encode(trace) else { return }
        let url = fileURL(for: trace.at, root: root)
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data)
        }
    }

    /// Today's and yesterday's traces (local calendar), newest `at` first,
    /// deduped by `(reminderId, at)` keeping the newest-written line and
    /// capped at `limit`. A file that cannot be read, or a line that cannot
    /// be decoded, is skipped rather than failing the whole read.
    static func recent(limit: Int = 50, now: Date = Date(), root: URL = ReminderTraceStore.root) -> [ReminderTrace] {
        // Read order is oldest file to newest, and within a file, append
        // (write) order — so for a given key, the last one seen here is
        // genuinely the last one written.
        let ordered = entries(on: now.addingTimeInterval(-86_400), root: root) + entries(on: now, root: root)
        var latest: [String: ReminderTrace] = [:]
        for trace in ordered { latest[dedupeKey(trace)] = trace }
        return Array(latest.values.sorted { $0.at > $1.at }.prefix(limit))
    }

    /// `(reminderId, at)` as a single string key — the identity the store
    /// dedupes on, shared with `ReminderReadoutService.recentTracesMerged`.
    ///
    /// `at` is rounded to whole seconds on purpose: the on-disk form is
    /// ISO-8601, which carries no sub-second part, so a trace still held in
    /// memory (full precision) and its own line on disk would otherwise key
    /// differently and the merged view would show the same reminder twice.
    /// Two genuinely distinct traces for one reminder id inside the same
    /// second do not occur — an id is claimed in `ReminderMemory` before it
    /// is spoken.
    static func dedupeKey(_ trace: ReminderTrace) -> String {
        "\(trace.reminderId ?? "")|\(trace.at.timeIntervalSince1970.rounded(.down))"
    }

    private static func fileURL(for date: Date, root: URL) -> URL {
        root.appendingPathComponent("traces-\(dayString(date)).jsonl", isDirectory: false)
    }

    private static func dayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = .current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private static func entries(on day: Date, root: URL) -> [ReminderTrace] {
        let url = fileURL(for: day, root: root)
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [ReminderTrace] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let trace = try? decoder.decode(ReminderTrace.self, from: lineData) else { continue }
            out.append(trace)
        }
        return out
    }

    private static func encode(_ trace: ReminderTrace) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(trace)
        guard let line = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return line
    }
}
