import Foundation

/// Body-free, durable record that a raw transcript session was written
/// without a registered Hub scanner. A failed first registration (runtime
/// absent, control store full or failing) used to leave only a log line and
/// a volatile `lastFailure`, so later appends looked merely unconfigured and
/// no consumer could tell the session was never covered. The marker lives
/// beside `raw.jsonl`, independent of the control store that may itself be
/// the failure. The first reason wins; nothing here retries or uploads.
enum AudioHubRawGapMarker {
    static let fileName = "hub-raw-gap.json"

    struct Marker: Codable, Equatable {
        let version: Int
        let sessionID: String
        let reason: String
        let recordedAt: String
    }

    @discardableResult
    static func record(sessionDirectory: URL, sessionID: String, reason: String, now: Date = Date()) -> Bool {
        let url = sessionDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) { return true }
        let marker = Marker(version: 1, sessionID: sessionID, reason: reason,
                            recordedAt: ISO8601DateFormatter().string(from: now))
        guard let data = try? JSONEncoder().encode(marker) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            chmod(url.path, 0o600)
            return true
        } catch {
            return false
        }
    }

    static func load(sessionDirectory: URL) -> Marker? {
        guard let data = try? Data(contentsOf: sessionDirectory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }
}
