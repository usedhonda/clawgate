import Foundation
import CryptoKit

/// A crash-safe multi-part generation. Only completed, validated parts are
/// checkpointed; an interrupted request resumes at the first unfinished part.
struct MeetingMinutesJob: Codable {
    let fingerprint: String
    let envelopes: [MeetingMinutesEnvelope]
    var completed: [MeetingMinutes?]
    var supplementalSnapshot: [MeetingSupplementalMaterial]? = nil
    /// Explicit owner request marker. Missing on legacy and automatic jobs.
    var userRequestedAt: Date? = nil
    /// Number of validated prefix parts carried from the prior input revision.
    var reusedPartCount: Int? = nil

    var allSupplementalMaterials: [MeetingSupplementalMaterial]? { supplementalSnapshot ?? envelopes.first?.supplementalMaterials }

    var materialCitationSnapshot: [MeetingSupplementalMaterial]? {
        guard let originals = allSupplementalMaterials else { return nil }
        return originals.map { material in
            var seen = Set<String>()
            let sections = envelopes.flatMap { $0.supplementalMaterials ?? [] }.filter { $0.id == material.id }
                .flatMap(\.sections).filter { seen.insert($0.id).inserted }
            return MeetingSupplementalMaterial(id: material.id, name: material.name, note: material.note,
                included: material.included, status: material.status, error: material.error,
                sections: sections.isEmpty ? material.sections : sections, addedAt: material.addedAt,
                originalRelativePath: material.originalRelativePath)
        }
    }

    var next: MeetingMinutesEnvelope? {
        completed.count < envelopes.count ? envelopes[completed.count] : nil
    }

    var frozenEnvelope: MeetingMinutesEnvelope? {
        guard let first = envelopes.first else { return nil }
        var seen = Set<String>()
        var result = first.replacingSegments(envelopes.flatMap(\.segments).filter { seen.insert($0.id).inserted })
        result.supplementalMaterials = allSupplementalMaterials
        return result
    }

    /// Updating reference material must not regenerate an unchanged speech
    /// prefix. Compare the complete durable envelope (including metadata and
    /// citation locators), not just its prompt projection. Stop at the first
    /// change: later outputs can depend on that earlier context.
    static func updating(_ envelope: MeetingMinutesEnvelope, previous: MeetingMinutesJob?,
                         requestedAt: Date = Date()) -> MeetingMinutesJob {
        let fresh = MeetingMinutes.chunked(envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func inputData(_ value: MeetingMinutesEnvelope) -> Data? {
            guard let data = try? encoder.encode(value),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            // A dispatch correlation id changes even when its input doesn't.
            object.removeValue(forKey: "requestId")
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        var kept: [MeetingMinutes?] = []
        // Same inputs + explicit regenerate means the owner wants a fresh
        // answer, not a no-op. Reuse is only for a genuinely changed revision.
        if let previous, previous.fingerprint != fingerprint(envelope) {
            for index in 0..<min(fresh.count, previous.envelopes.count, previous.completed.count) {
                guard let before = inputData(previous.envelopes[index]),
                      let after = inputData(fresh[index]), before == after else { break }
                kept.append(previous.completed[index])
            }
        }
        return MeetingMinutesJob(fingerprint: fingerprint(envelope), envelopes: fresh,
                                 completed: kept, supplementalSnapshot: envelope.supplementalMaterials,
                                 userRequestedAt: requestedAt, reusedPartCount: kept.count)
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
            let supplementalMaterials: [MeetingSupplementalMaterial]?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Revision(policyVersion: envelope.policyVersion,
                                                  segments: envelope.segments,
                                                  unresolvedNotes: envelope.unresolvedNotes ?? [],
                                                  supplementalMaterials: envelope.supplementalMaterials))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Same spoken input, newer meeting metadata: keep every written part and
    /// let the parts still to be sent carry the current metadata.
    func refreshingMetadata(from envelope: MeetingMinutesEnvelope) -> MeetingMinutesJob {
        let fresh = MeetingMinutes.chunked(envelope)
        guard fresh.count == envelopes.count else { return self }
        return MeetingMinutesJob(fingerprint: fingerprint, envelopes: fresh, completed: completed,
                                 supplementalSnapshot: supplementalSnapshot, userRequestedAt: userRequestedAt,
                                 reusedPartCount: reusedPartCount)
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
