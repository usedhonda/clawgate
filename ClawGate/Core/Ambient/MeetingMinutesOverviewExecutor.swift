import Foundation
import CryptoKit

/// Durable, single-request overview rewrite for a completed minutes ledger.
/// This is deliberately inactive until a caller supplies the dedicated Gateway
/// activation gate; ordinary chat is never used as a fallback.
actor MeetingMinutesOverviewExecutor {
    enum State: Equatable {
        case pending
        case completed(MeetingMinutes?)
        case failed
        case recovering
        case unavailable
    }

    enum Failure: Error, Equatable {
        case invalidJob
        case stalePublication
        case persistence
    }

    typealias Send = (MinutesExecutionSendParams) async throws -> MinutesExecutionAck
    typealias Read = (MinutesExecutionSendParams) async throws -> MinutesExecutionRead

    private let frozenJob: MeetingMinutesJob
    private let completedJob: MeetingMinutesJob
    private let record: MeetingRecord
    private let store: MeetingStore
    private let id: String
    private let sessionKey: String
    private let send: Send
    private let read: Read
    private let overviewJob: MeetingMinutesJob?
    private let base: MeetingMinutes?
    private let parts: [MeetingMinutes]
    private let input: MeetingMinutesSummaryPass.Input?
    private var ledger: MeetingMinutesExecutionState?
    private var busy = false

    init(frozenJob: MeetingMinutesJob, completedJob: MeetingMinutesJob,
         record: MeetingRecord, store: MeetingStore, id: String, sessionKey: String,
         send: @escaping Send, read: @escaping Read) throws {
        guard id == record.id,
              frozenJob.fingerprint == completedJob.fingerprint,
              frozenJob.envelopes == completedJob.envelopes,
              frozenJob.supplementalSnapshot == completedJob.supplementalSnapshot,
              frozenJob.reusedPartCount == completedJob.reusedPartCount,
              completedJob.completed.count >= frozenJob.completed.count,
              Array(completedJob.completed.prefix(frozenJob.completed.count)) == frozenJob.completed,
              completedJob.completed.count == completedJob.envelopes.count else {
            throw Failure.invalidJob
        }
        self.frozenJob = frozenJob; self.completedJob = completedJob
        self.record = record; self.store = store; self.id = id; self.sessionKey = sessionKey
        self.send = send; self.read = read
        guard let snapshot = completedJob.frozenEnvelope,
              let startedAt = ISO8601DateFormatter().date(from: snapshot.startedAt),
              TimeZone(identifier: snapshot.timeZone) != nil else { throw Failure.invalidJob }
        // Overview input belongs to the frozen generation, not later edits to
        // calendar/title metadata on the convenience meeting record.
        var inputRecord = record
        inputRecord.startedAt = startedAt.timeIntervalSince1970
        inputRecord.timeZone = snapshot.timeZone
        inputRecord.title = snapshot.title
        inputRecord.calendarEventID = snapshot.calendarEventID
        let values = completedJob.completed.compactMap { $0 }
        self.parts = values
        let derivedBase = MeetingMinutes.combining(values)?.boundToCalendarEvent(snapshot.calendarEventID)
        self.base = derivedBase
        guard let envelope = completedJob.frozenEnvelope,
              let base = derivedBase, !values.isEmpty,
              MeetingMinutesSummaryPass.needed(partCount: values.count) else {
            overviewJob = nil; input = nil
            ledger = nil
            return
        }
        let summaryInput = MeetingMinutesSummaryPass.input(for: base, parts: values, record: inputRecord)
        self.input = summaryInput
        let fingerprint = try Self.overviewFingerprint(original: frozenJob.fingerprint,
                                                        envelopes: completedJob.envelopes,
                                                        envelope: envelope, base: base,
                                                        input: summaryInput)
        let job = MeetingMinutesJob(fingerprint: fingerprint, envelopes: [envelope], completed: [],
                                    supplementalSnapshot: envelope.supplementalMaterials)
        self.overviewJob = job
        self.ledger = try MeetingMinutesExecutionState.load(store: store, id: id, job: job)
            ?? MeetingMinutesExecutionState(job: job)
    }

    /// True after the overview answer has reached the durable ledger terminal.
    func hasCompletedOutcome() -> Bool {
        guard let part = ledger?.parts.first else { return false }
        return part.status == .completed && part.outcome != nil
    }

    func step() async throws -> State {
        guard !busy else { throw Failure.persistence }
        busy = true; defer { busy = false }
        guard let overviewJob, var ledger, let base, let input else {
            return .completed(base)
        }

        if hasCompletedOutcome() {
            let published = try publish(base: base, ledger: ledger, overviewJob: overviewJob)
            self.ledger = ledger
            return .completed(published)
        }

        let dispatches = ledger.recoverableDispatches
        if let dispatch = dispatches.first {
            let result: MinutesExecutionRead
            do { result = try await read(dispatch.request) }
            catch { self.ledger = ledger; return .recovering }
            guard result.binding?.matches(dispatch.request) == true else { return .unavailable }
            if result.result == .expired || result.result == .notFound {
                self.ledger = ledger; return .unavailable
            }
            if ledger.parts[dispatch.index].status == .submitting {
                try ledger.reconcile(dispatch, read: result, store: store, id: id)
            }
            switch result.result {
            case .pending: self.ledger = ledger; return .pending
            case .expired, .notFound: self.ledger = ledger; return .unavailable
            case .answer(let text):
                guard let parsedInput = self.input else { return .failed }
                let rewritten: MeetingMinutes
                do {
                    let reply = try MeetingMinutesSummaryPass.parse(text, input: parsedInput)
                    rewritten = MeetingMinutesSummaryPass.apply(reply, to: base, parts: parts)
                } catch {
                    try ledger.failTerminal(dispatch, runId: dispatch.idempotencyKey,
                                            code: "invalid_answer", retryable: false,
                                            store: store, id: id)
                    self.ledger = ledger; return .failed
                }
                try ledger.complete(dispatch, runId: dispatch.idempotencyKey,
                                    outcome: .answer(rewritten), store: store, id: id)
            case .failed(let code, let retryable):
                try ledger.failTerminal(dispatch, runId: dispatch.idempotencyKey,
                                        code: code, retryable: retryable, store: store, id: id)
                self.ledger = ledger; return .failed
            case .aborted:
                try ledger.failTerminal(dispatch, runId: dispatch.idempotencyKey,
                                        code: "aborted", retryable: false, store: store, id: id)
                self.ledger = ledger; return .failed
            }
            self.ledger = ledger
            let published = try publish(base: base, ledger: ledger, overviewJob: overviewJob)
            return .completed(published)
        }

        guard !ledger.parts.contains(where: { $0.status == .failed }),
              let message = try? MeetingMinutesSummaryPass.buildMessage(input: input) else {
            self.ledger = ledger; return .failed
        }
        let dispatch = try ledger.reserve(index: 0, sessionKey: sessionKey, message: message,
                                          store: store, id: id)
        self.ledger = ledger
        let ack: MinutesExecutionAck
        do { ack = try await send(dispatch.request) }
        catch { return .recovering }
        try ledger.acknowledge(dispatch, ack: ack, store: store, id: id)
        self.ledger = ledger
        return .pending
    }

    private func publish(base: MeetingMinutes, ledger: MeetingMinutesExecutionState,
                         overviewJob: MeetingMinutesJob) throws -> MeetingMinutes {
        guard let outcome = ledger.parts.first?.outcome,
              case .answer(let rewritten) = outcome else { throw Failure.persistence }
        return try MeetingMinutesJob.withCurrentRevisionLock(store: store, id: id, expected: frozenJob) {
            guard let authoritative = try MeetingMinutesExecutionState.load(store: store, id: id,
                                                                              job: overviewJob),
                  authoritative == ledger else { throw Failure.stalePublication }
            guard let accepted = store.loadAcceptedMinutes(id: id),
                  accepted.fingerprint == frozenJob.fingerprint,
                  Self.acceptedMatches(accepted, minutes: base, job: frozenJob) ||
                  Self.acceptedMatches(accepted, minutes: rewritten, job: frozenJob) else {
                throw Failure.stalePublication
            }
            if accepted.minutes == rewritten { return rewritten }
            try store.saveValidatedMinutes(rewritten, for: record, job: completedJob)
            return rewritten
        }
    }

    private static func acceptedMatches(_ accepted: MeetingAcceptedMinutes,
                                        minutes: MeetingMinutes,
                                        job: MeetingMinutesJob) -> Bool {
        accepted.minutes == minutes && accepted.fingerprint == job.fingerprint &&
        accepted.segments == uniqueSegments(job.envelopes.flatMap(\.segments)) &&
        accepted.unresolvedNotes == (job.envelopes.first?.unresolvedNotes ?? []) &&
        accepted.supplementalMaterials == job.materialCitationSnapshot &&
        accepted.supplementalInput == job.allSupplementalMaterials
    }

    private static func uniqueSegments(_ values: [MeetingMinutesSegment]) -> [MeetingMinutesSegment] {
        var seen = Set<String>(); return values.filter { seen.insert($0.id).inserted }
    }

    private static func overviewFingerprint(original: String, envelopes: [MeetingMinutesEnvelope],
                                            envelope: MeetingMinutesEnvelope,
                                            base: MeetingMinutes,
                                            input: MeetingMinutesSummaryPass.Input) throws -> String {
        struct Fingerprint: Encodable { let domain: String; let original: String; let envelopeHashes: [String]; let envelope: MeetingMinutesEnvelope; let base: MeetingMinutes; let input: MeetingMinutesSummaryPass.Input }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let hashes = try envelopes.map { SHA256.hash(data: try encoder.encode($0)).map { String(format: "%02x", $0) }.joined() }
        return SHA256.hash(data: try encoder.encode(Fingerprint(domain: "overview-v1", original: original, envelopeHashes: hashes, envelope: envelope, base: base, input: input))).map { String(format: "%02x", $0) }.joined()
    }
}
