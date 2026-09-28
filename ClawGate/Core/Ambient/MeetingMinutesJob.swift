import Foundation
import CryptoKit

/// A crash-safe multi-part generation. Only completed, validated parts are
/// checkpointed; an interrupted request resumes at the first unfinished part.
struct MeetingMinutesJob: Codable {
    let fingerprint: String
    let envelopes: [MeetingMinutesEnvelope]
    var completed: [MeetingMinutes?]

    var next: MeetingMinutesEnvelope? {
        completed.count < envelopes.count ? envelopes[completed.count] : nil
    }

    static func fingerprint(_ envelope: MeetingMinutesEnvelope) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Request IDs are per-attempt, not input revisions.
        let data = (try? encoder.encode(envelope)) ?? Data()
        var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        object.removeValue(forKey: "requestId")
        let stable = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
        return SHA256.hash(data: stable).map { String(format: "%02x", $0) }.joined()
    }

    static func load(store: MeetingStore, id: String) -> MeetingMinutesJob? {
        let url = store.directory(for: id).appendingPathComponent("minutes-job.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(store: MeetingStore, id: String) throws {
        let dir = store.directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: dir.appendingPathComponent("minutes-job.json"), options: .atomic)
    }
}
