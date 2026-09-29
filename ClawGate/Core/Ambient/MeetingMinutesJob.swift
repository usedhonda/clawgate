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

    /// The input revision: what was said, not what the meeting is called.
    /// Calendar association, title or schedule arriving after the first
    /// request used to change this and throw away parts already written
    /// (2026-09-29); only the spoken segments and the unresolved conflicts
    /// that travel with them decide whether a generation is still current.
    static func fingerprint(_ envelope: MeetingMinutesEnvelope) -> String {
        struct Revision: Encodable {
            let policyVersion: String
            let segments: [MeetingMinutesSegment]
            let unresolvedNotes: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Revision(policyVersion: envelope.policyVersion,
                                                  segments: envelope.segments,
                                                  unresolvedNotes: envelope.unresolvedNotes ?? []))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Same spoken input, newer meeting metadata: keep every written part and
    /// let the parts still to be sent carry the current metadata.
    func refreshingMetadata(from envelope: MeetingMinutesEnvelope) -> MeetingMinutesJob {
        let fresh = MeetingMinutes.chunked(envelope)
        guard fresh.count == envelopes.count else { return self }
        return MeetingMinutesJob(fingerprint: fingerprint, envelopes: fresh, completed: completed)
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
