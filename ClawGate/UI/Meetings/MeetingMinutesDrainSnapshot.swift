import Foundation

struct MeetingMinutesDrainSnapshot {
    struct PreparationFailure: Error {
        let record: MeetingRecord
        let files: [String: String]
        let error: Error
    }
    let record: MeetingRecord
    let job: MeetingMinutesJob
    let files: [String: String]
    let envelope: MeetingMinutesEnvelope
    let windows: [MeetingConflictReview.Window]
    let reviewKey: String
    let needsReview: Bool
    let message: String?
    let combined: MeetingMinutes?

    static func load(store: MeetingStore, sessionsRoot: URL,
                     transcript: ((MeetingRecord) -> [TranscriptSegment])?,
                     materials: [String: MeetingGoogleMaterials.Snapshot],
                     notBefore: [String: Date], preparing: Set<String>, now: Date,
                     ticket: MeetingMinutesPreparation.Ticket) throws -> Self? {
        try ticket.check()
        let pilot = MeetingMinutesPilot.load()
        let ordered = PetModel.pendingMinutesOrder(store.all(), store: store)
        guard let record = ordered.first(where: { record in
            guard !preparing.contains(record.id), (notBefore[record.id] ?? .distantPast) <= now else { return false }
            let job = MeetingMinutesJob.load(store: store, id: record.id)
            let pilotOwned = job.map { pilot?.matches(store: store, id: record.id, job: $0) == true } ?? false
            return !MeetingMinutesPreparation.hasIndexedOwner(store: store, id: record.id, job: job)
                && !pilotOwned
        }) else { return nil }
        let directory = store.directory(for: record.id)
        var files = try MeetingMinutesSourceRevision.files(in: directory)
        if MeetingMinutesJob.load(store: store, id: record.id) == nil {
            let output: MeetingMinutesPreparation.Output
            do {
                output = try MeetingMinutesPreparation.run(.init(record: record, store: store, sessionsRoot: sessionsRoot,
                    material: record.materialCandidateID.flatMap { materials[$0] }, transcript: transcript,
                    preservingMaterials: false, refreshPreparedInput: false, regenerate: false, forceFull: false),
                    ticket: ticket)
            } catch {
                throw PreparationFailure(record: record, files: files, error: error)
            }
            guard !output.owned else { throw MeetingMinutesPreparation.Failure.changed }
            files = output.files
        }
        guard let job = MeetingMinutesJob.load(store: store, id: record.id),
              let envelope = job.frozenEnvelope else {
            throw PreparationFailure(record: record, files: files, error: MeetingMinutesPreparation.Failure.noTranscript)
        }
        let raw = envelope.segments.filter { $0.source != "audio-recheck" }.map {
            MeetingTranscriptSourceSegment(id: $0.id, source: $0.source, text: $0.text, capturedAt: $0.capturedAt)
        }
        let conflicts = MeetingTranscriptFusion.fuse(sourceSegments: raw)
        let windows = MeetingConflictReview.windows(times: conflicts.conflictTimes, record: record)
        let reviewKey = MeetingConflictReview.fingerprint(record: record, windows: windows)
        let needsReview = job.completed.isEmpty && !windows.isEmpty
            && MeetingConflictReview.load(record: record, fingerprint: reviewKey, store: store) == nil
        let message = job.next.flatMap { try? MeetingMinutesPrompt.buildMessage(envelope: $0) }
        let combined = !job.envelopes.isEmpty && job.next == nil
            ? MeetingMinutes.combining(job.completed.compactMap { $0 }) : nil
        guard store.load(id: record.id) == record, try MeetingMinutesSourceRevision.files(in: directory) == files else {
            throw MeetingMinutesPreparation.Failure.changed
        }
        try ticket.check()
        return Self(record: record, job: job, files: files, envelope: envelope, windows: windows,
            reviewKey: reviewKey, needsReview: needsReview, message: message, combined: combined)
    }
}
