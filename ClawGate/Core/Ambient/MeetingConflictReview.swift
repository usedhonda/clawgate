import CryptoKit
import Foundation

struct MeetingConflictReview {
    struct Window: Codable, Equatable { let start: Double; let end: Double; var duration: Double { end - start } }
    struct Result: Codable { let fingerprint: String; let segments: [TranscriptSegment]; let error: String? }
    static func windows(times: [Double], record: MeetingRecord) -> [Window] {
        var windows: [Window] = []
        for time in times.sorted() where !windows.contains(where: { $0.start <= time && time <= $0.end }) {
            let start = max(record.startedAt, time - 8)
            let end = min(record.endedAt ?? time + 20, time + 20)
            if start < end { windows.append(Window(start: start, end: end)) }
            if windows.count == 3 { break }
        }
        return windows
    }
    static func fingerprint(record: MeetingRecord, windows: [Window]) -> String { SHA256.hash(data: Data((record.id + windows.map { "\($0.start)-\($0.end)" }.joined()).utf8)).map { String(format: "%02x", $0) }.joined() }
    static func load(record: MeetingRecord, fingerprint: String, store: MeetingStore) -> Result? { try? JSONDecoder().decode(Result.self, from: Data(contentsOf: store.directory(for: record.id).appendingPathComponent("conflict-review-\(fingerprint).json"))) }
    static func save(_ result: Result, record: MeetingRecord, store: MeetingStore) throws { let dir = store.directory(for: record.id); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); try JSONEncoder().encode(result).write(to: dir.appendingPathComponent("conflict-review-\(result.fingerprint).json"), options: .atomic) }
}
