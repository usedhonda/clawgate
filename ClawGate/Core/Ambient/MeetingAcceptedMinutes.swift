import Foundation

/// One atomic commit point for the readable document and the exact input
/// revision supporting its citations. A failed generation never touches it.
struct MeetingAcceptedMinutes: Codable {
    let minutes: MeetingMinutes
    let fingerprint: String
    let segments: [MeetingMinutesSegment]
    let unresolvedNotes: [String]
    let createdAt: Date
    var supplementalMaterials: [MeetingSupplementalMaterial]? = nil
    var supplementalInput: [MeetingSupplementalMaterial]? = nil
    /// Present only on newly accepted generations. Legacy documents are not
    /// implicitly enrolled for knowledge sharing during startup reconciliation.
    var knowledgeContext: MeetingMinutesKnowledgeSnapshot.Context? = nil
    var coverageHints: [String]? = nil
}

extension MeetingStore {
    private static func uniqueSegments(_ values: [MeetingMinutesSegment]) -> [MeetingMinutesSegment] {
        var seen = Set<String>(); return values.filter { seen.insert($0.id).inserted }
    }

    func loadAcceptedMinutes(id: String) -> MeetingAcceptedMinutes? {
        guard let data = try? Data(contentsOf: directory(for: id).appendingPathComponent("minutes-accepted.json")) else { return nil }
        return try? JSONDecoder().decode(MeetingAcceptedMinutes.self, from: data)
    }

    func saveValidatedMinutes(_ minutes: MeetingMinutes, for record: MeetingRecord,
                              job: MeetingMinutesJob) throws {
        guard !job.envelopes.isEmpty, job.completed.count == job.envelopes.count,
              job.completed.contains(where: { $0 != nil }) else { throw MeetingMinutesError.encodingFailed }
        let accepted = MeetingAcceptedMinutes(minutes: minutes, fingerprint: job.fingerprint,
            segments: Self.uniqueSegments(job.envelopes.flatMap(\.segments)),
            unresolvedNotes: job.envelopes.first?.unresolvedNotes ?? [], createdAt: Date(),
            supplementalMaterials: job.materialCitationSnapshot, supplementalInput: job.allSupplementalMaterials,
            knowledgeContext: MeetingMinutesKnowledgeSnapshot.Context(record: record),
            coverageHints: job.envelopes.first?.coverageHints)
        let dir = directory(for: record.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let acceptedData = try JSONEncoder().encode(accepted)
        try acceptedData.write(to: dir.appendingPathComponent("minutes-accepted.json"), options: .atomic)
        MeetingMinutesPublisher.didAccept(store: self, record: record, acceptedData: acceptedData)
        // These are export copies. The accepted file above is the authority.
        saveMinutes(minutes, for: record)
    }
}
