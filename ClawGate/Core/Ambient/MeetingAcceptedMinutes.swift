import Foundation

/// One atomic commit point for the readable document and the exact input
/// revision supporting its citations. A failed generation never touches it.
struct MeetingAcceptedMinutes: Codable {
    let minutes: MeetingMinutes
    let fingerprint: String
    let segments: [MeetingMinutesSegment]
    let unresolvedNotes: [String]
    let createdAt: Date
}

extension MeetingStore {
    func loadAcceptedMinutes(id: String) -> MeetingAcceptedMinutes? {
        guard let data = try? Data(contentsOf: directory(for: id).appendingPathComponent("minutes-accepted.json")) else { return nil }
        return try? JSONDecoder().decode(MeetingAcceptedMinutes.self, from: data)
    }

    func saveValidatedMinutes(_ minutes: MeetingMinutes, for record: MeetingRecord,
                              job: MeetingMinutesJob) throws {
        guard !job.envelopes.isEmpty, job.completed.count == job.envelopes.count,
              job.completed.contains(where: { $0 != nil }) else { throw MeetingMinutesError.encodingFailed }
        let accepted = MeetingAcceptedMinutes(minutes: minutes, fingerprint: job.fingerprint,
            segments: job.envelopes.flatMap(\.segments),
            unresolvedNotes: job.envelopes.first?.unresolvedNotes ?? [], createdAt: Date())
        let dir = directory(for: record.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(accepted).write(to: dir.appendingPathComponent("minutes-accepted.json"), options: .atomic)
        // These are export copies. The accepted file above is the authority.
        saveMinutes(minutes, for: record)
    }
}
