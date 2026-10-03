import Foundation

/// Commits a complete indexed execution ledger as the readable minutes bundle.
///
/// The job passed to this type is a frozen revision.  It is deliberately not
/// advanced here: the caller may checkpoint the returned `completedJob` after
/// this commit point.  The current job is checked under the job revision lock
/// immediately before the accepted bundle is written, so a changed input can
/// never be replaced by results from an older revision.
struct MeetingMinutesExecutionFinalizer {
    enum FinalizationError: Error, Equatable {
        case invalidLedger
        case incomplete
        case noMinutes
        case staleJob
    }

    struct Result {
        let completedJob: MeetingMinutesJob
        let combined: MeetingMinutes
        /// False when the accepted bundle already contained the exact same
        /// minutes for this input revision and no bytes were rewritten.
        let wroteAcceptedBundle: Bool
    }

    /// Finalize `ledger` against its frozen input revision and atomically
    /// publish the combined minutes.  Errors occur before publication, so an
    /// older accepted bundle remains authoritative on every rejection.
    static func finalize(ledger: MeetingMinutesExecutionState,
                         frozenJob: MeetingMinutesJob,
                         record: MeetingRecord,
                         store: MeetingStore,
                         id: String) throws -> Result {
        let prepared = try prepare(ledger: ledger, frozenJob: frozenJob, record: record, id: id)
        let completedJob = prepared.completedJob
        let bound = prepared.combined
        return try MeetingMinutesJob.withCurrentRevisionLock(store: store, id: id, expected: frozenJob) {
            guard let currentLedger = try MeetingMinutesExecutionState.load(store: store, id: id, job: frozenJob),
                  currentLedger == ledger else {
                throw FinalizationError.staleJob
            }
            if let accepted = store.loadAcceptedMinutes(id: id),
               accepted.fingerprint == frozenJob.fingerprint,
               accepted.minutes == bound,
               accepted.segments == Self.uniqueSegments(frozenJob.envelopes.flatMap(\.segments)),
               accepted.unresolvedNotes == (frozenJob.envelopes.first?.unresolvedNotes ?? []),
               accepted.supplementalMaterials == frozenJob.materialCitationSnapshot,
               accepted.supplementalInput == frozenJob.allSupplementalMaterials {
                return Result(completedJob: completedJob, combined: bound,
                              wroteAcceptedBundle: false)
            }
            try store.saveValidatedMinutes(bound, for: record, job: completedJob)
            return Result(completedJob: completedJob, combined: bound,
                          wroteAcceptedBundle: true)
        }
    }

    /// Prepare exact source-ordered output without replacing an already
    /// published overview during restart recovery.
    static func prepare(ledger: MeetingMinutesExecutionState, frozenJob: MeetingMinutesJob,
                        record: MeetingRecord, id: String) throws -> Result {
        guard id == record.id,
              ledger.version == MeetingMinutesExecutionState.currentVersion,
              ledger.fingerprint == frozenJob.fingerprint,
              !frozenJob.envelopes.isEmpty,
              frozenJob.completed.count <= frozenJob.envelopes.count,
              ledger.parts.count == frozenJob.envelopes.count,
              ledger.parts.map(\.index) == Array(frozenJob.envelopes.indices) else {
            throw FinalizationError.invalidLedger
        }

        var completed: [MeetingMinutes?] = []
        completed.reserveCapacity(ledger.parts.count)
        for (index, part) in ledger.parts.enumerated() {
            guard (try? MeetingMinutesExecutionState.hash(frozenJob.envelopes[index])) == part.envelopeHash,
                  part.status == .completed,
                  let outcome = part.outcome else {
                throw FinalizationError.incomplete
            }
            if index < frozenJob.completed.count {
                let expected: MeetingMinutesExecutionState.Outcome =
                    frozenJob.completed[index].map(MeetingMinutesExecutionState.Outcome.answer)
                    ?? .insufficientEvidence
                guard outcome == expected else { throw FinalizationError.invalidLedger }
            }
            switch outcome {
            case .insufficientEvidence:
                completed.append(nil)
            case .answer(let minutes):
                completed.append(minutes)
            }
        }

        guard let combined = MeetingMinutes.combining(completed.compactMap { $0 }) else {
            throw FinalizationError.noMinutes
        }
        let completedJob = MeetingMinutesJob(
            fingerprint: frozenJob.fingerprint,
            envelopes: frozenJob.envelopes,
            completed: completed,
            supplementalSnapshot: frozenJob.supplementalSnapshot,
            userRequestedAt: frozenJob.userRequestedAt,
            reusedPartCount: frozenJob.reusedPartCount)

        return Result(completedJob: completedJob,
                      combined: combined.boundToCalendarEvent(frozenJob.envelopes.first?.calendarEventID),
                      wroteAcceptedBundle: false)
    }

    private static func uniqueSegments(_ values: [MeetingMinutesSegment]) -> [MeetingMinutesSegment] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }
}
