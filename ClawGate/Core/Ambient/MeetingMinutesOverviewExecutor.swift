import Foundation
import CryptoKit

/// Durable, staged whole-meeting reconciliation for a completed minutes ledger.
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
    private let legacySingleRequest: Bool
    private var busy = false
    private var correctionRequestKey: String?
    private let correctionRequested: Bool

    init(frozenJob: MeetingMinutesJob, completedJob: MeetingMinutesJob,
         record: MeetingRecord, store: MeetingStore, id: String, sessionKey: String,
         send: @escaping Send, read: @escaping Read, correctionRequested: Bool = false) throws {
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
        self.correctionRequested = correctionRequested
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
              MeetingMinutesSummaryPass.needed(for: completedJob) else {
            overviewJob = nil; input = nil
            ledger = nil; legacySingleRequest = false
            return
        }
        let summaryInput = MeetingMinutesSummaryPass.input(for: base, parts: values, record: inputRecord, segments: envelope.segments)
        self.input = summaryInput
        // An already reserved single-pass owner must finish on its original
        // exact request. A deployment must not create a parallel tree owner.
        let legacyFingerprint = try Self.overviewFingerprint(original: frozenJob.fingerprint,
            envelopes: completedJob.envelopes, envelope: envelope, base: base,
            input: summaryInput, domain: "overview-v1")
        let legacyJob = MeetingMinutesJob(fingerprint: legacyFingerprint, envelopes: [envelope],
            completed: [], supplementalSnapshot: envelope.supplementalMaterials)
        if let existing = try MeetingMinutesExecutionState.load(store: store, id: id, job: legacyJob) {
            self.overviewJob = legacyJob; self.ledger = existing
            self.legacySingleRequest = true
            self.correctionRequestKey = correctionRequested ? existing.rejectedAnswerDispatches.first?.idempotencyKey : nil
            return
        }
        self.legacySingleRequest = false
        let fingerprint = try Self.overviewFingerprint(original: frozenJob.fingerprint,
                                                        envelopes: completedJob.envelopes,
                                                        envelope: envelope, base: base,
                                                        input: summaryInput)
        let stageCount = MeetingMinutesSummaryPass.stages(partCount: values.count).count
        let job = MeetingMinutesJob(fingerprint: fingerprint,
                                    envelopes: Array(repeating: envelope, count: stageCount), completed: [],
                                    supplementalSnapshot: envelope.supplementalMaterials)
        self.overviewJob = job
        self.ledger = try MeetingMinutesExecutionState.load(store: store, id: id, job: job)
            ?? MeetingMinutesExecutionState(job: job)
        self.correctionRequestKey = correctionRequested ? self.ledger?.rejectedAnswerDispatches.first?.idempotencyKey : nil
    }

    /// True after the overview answer has reached the durable ledger terminal.
    func hasCompletedOutcome() -> Bool {
        guard let parts = ledger?.parts, !parts.isEmpty else { return false }
        return parts.allSatisfy { $0.status == .completed && $0.outcome != nil }
    }

    func step() async throws -> State {
        guard !busy else { throw Failure.persistence }
        busy = true; defer { busy = false }
        guard let overviewJob, var ledger, let base, input != nil else {
            return .completed(base)
        }

        if let invalid = ledger.parts.first(where: { part in
            guard part.status == .completed, case .answer(let minutes) = part.outcome else { return false }
            return !Set(minutes.openQuestions).isDisjoint(with: Set(minutes.decisions + minutes.actionItems.map(\.what)))
        }) {
            guard correctionRequested, !legacySingleRequest, let input else { return .failed }
            let plan = MeetingMinutesSummaryPass.stages(partCount: input.parts.count)
            var affected = Set([input.parts.count + invalid.index])
            for index in plan.indices where plan[index].contains(where: { affected.contains($0) }) {
                guard ledger.parts[index].status != .completed else { return .failed }
                affected.insert(input.parts.count + index)
            }
            try MeetingMinutesJob.withCurrentRevisionLock(store: store, id: id, expected: frozenJob) {
                try ledger.rejectContradictoryCompletedAnswer(index: invalid.index, store: store, id: id)
            }
            correctionRequestKey = invalid.idempotencyKey
            self.ledger = ledger
        }

        if hasCompletedOutcome() {
            let published = try publish(base: base, ledger: ledger, overviewJob: overviewJob)
            self.ledger = ledger
            return .completed(published)
        }

        let dispatches = ledger.recoverableDispatches + ledger.rejectedAnswerDispatches
        if let dispatch = dispatches.first {
            let revalidating = ledger.parts[dispatch.index].status == .failed
            if revalidating {
                let stage = try stageInput(index: dispatch.index, ledger: ledger)
                let part = ledger.parts[dispatch.index]
                let original = try MeetingMinutesSummaryPass.buildMessage(input: stage)
                let reviewed = try MeetingMinutesSummaryPass.buildReviewedMessage(input: stage)
                let expected: String
                if part.answerCorrection == nil {
                    guard dispatch.request.message == original || dispatch.request.message == reviewed else { return .failed }
                    expected = dispatch.request.message
                }
                else if part.answerCorrection?.reviewedPrompt == true {
                    expected = try MeetingMinutesSummaryPass.buildReviewedCorrectionMessage(input: stage)
                } else { expected = try MeetingMinutesSummaryPass.buildCorrectionMessage(input: stage) }
                guard expected == dispatch.request.message,
                      part.answerCorrection.map({ $0.rejectedRequest.message == original || $0.rejectedRequest.message == reviewed }) ?? true else { return .failed }
            }
            let result: MinutesExecutionRead
            do { result = try await read(dispatch.request) }
            catch { self.ledger = ledger; return .recovering }
            guard result.binding?.matches(dispatch.request) == true else { return .unavailable }
            if result.result == .expired || result.result == .notFound {
                self.ledger = ledger; return .unavailable
            }
            if revalidating {
                guard result.binding == ledger.parts[dispatch.index].executionBinding,
                      case .answer = result.result else { return .failed }
            }
            if ledger.parts[dispatch.index].status == .submitting {
                try ledger.reconcile(dispatch, read: result, store: store, id: id)
            }
            switch result.result {
            case .pending: self.ledger = ledger; return .pending
            case .expired, .notFound: self.ledger = ledger; return .unavailable
            case .answer(let text):
                let rewritten: MeetingMinutes
                do {
                    let parsedInput = try stageInput(index: dispatch.index, ledger: ledger)
                    let reply = try MeetingMinutesSummaryPass.parse(text, input: parsedInput)
                    rewritten = MeetingMinutesSummaryPass.apply(reply, to: base, parts: parsedInput.parts)
                    try MeetingMinutesSecondaryEvidence.validate(rewritten, segments: completedJob.envelopes.flatMap(\.segments))
                } catch {
                    if revalidating {
                        guard correctionRequestKey == dispatch.idempotencyKey,
                              ledger.parts[dispatch.index].answerCorrection == nil,
                              MeetingMinutesSummaryPass.permitsEvidenceCorrection(error) else { return .failed }
                        let message = try MeetingMinutesSummaryPass.buildReviewedCorrectionMessage(input: stageInput(index: dispatch.index, ledger: ledger))
                        let correction = try MeetingMinutesJob.withCurrentRevisionLock(store: store, id: id, expected: frozenJob) {
                            try ledger.reserveAnswerCorrection(dispatch, message: message, reviewedPrompt: true, store: store, id: id)
                        }
                        correctionRequestKey = nil
                        self.ledger = ledger
                        let ack: MinutesExecutionAck
                        do { ack = try await send(correction.request) }
                        catch { return .recovering }
                        try ledger.acknowledge(correction, ack: ack, store: store, id: id)
                        self.ledger = ledger
                        return .pending
                    }
                    try ledger.failTerminal(dispatch, runId: dispatch.idempotencyKey,
                                            code: "invalid_answer", retryable: false,
                                            store: store, id: id)
                    self.ledger = ledger; return .failed
                }
                if revalidating, let binding = result.binding {
                    try ledger.completeRevalidatedAnswer(dispatch, binding: binding,
                        minutes: rewritten, store: store, id: id)
                } else {
                    try ledger.complete(dispatch, runId: dispatch.idempotencyKey,
                                        outcome: .answer(rewritten), store: store, id: id)
                }
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
            guard hasCompletedOutcome() else { return .pending }
            let published = try publish(base: base, ledger: ledger, overviewJob: overviewJob)
            return .completed(published)
        }

        guard !ledger.parts.contains(where: { $0.status == .failed }),
              let index = ledger.parts.firstIndex(where: { $0.status != .completed }),
              let stage = try? stageInput(index: index, ledger: ledger),
              let message = try? MeetingMinutesSummaryPass.buildReviewedMessage(input: stage) else {
            self.ledger = ledger; return .failed
        }
        let dispatch = try ledger.reserve(index: index, sessionKey: sessionKey, message: message,
                                          store: store, id: id)
        self.ledger = ledger
        let ack: MinutesExecutionAck
        do { ack = try await send(dispatch.request) }
        catch { return .recovering }
        try ledger.acknowledge(dispatch, ack: ack, store: store, id: id)
        self.ledger = ledger
        return .pending
    }

    private func stageInput(index: Int, ledger: MeetingMinutesExecutionState) throws -> MeetingMinutesSummaryPass.Input {
        guard let input else { throw Failure.invalidJob }
        if legacySingleRequest { return input }
        let plan = MeetingMinutesSummaryPass.stages(partCount: input.parts.count)
        guard plan.indices.contains(index), let base else { throw Failure.persistence }
        let dependencies = Set(plan[index].filter { $0 >= input.parts.count }.map { $0 - input.parts.count })
        let completed = try ledger.parts.prefix(index).map { part -> MeetingMinutes in
            if part.status == .completed, case .answer(let minutes) = part.outcome { return minutes }
            guard !dependencies.contains(part.index) else { throw Failure.persistence }
            // stageInput selects only this node's exact dependencies. A retained
            // result of an independent branch need not be regenerated.
            return base
        }
        return try MeetingMinutesSummaryPass.stageInput(original: input, index: index, completed: completed)
    }

    private func publish(base: MeetingMinutes, ledger: MeetingMinutesExecutionState,
                         overviewJob: MeetingMinutesJob) throws -> MeetingMinutes {
        guard ledger.parts.allSatisfy({ $0.status == .completed }),
              let outcome = ledger.parts.last?.outcome,
              case .answer(let rewritten) = outcome else { throw Failure.persistence }
        return try MeetingMinutesJob.withCurrentRevisionLock(store: store, id: id, expected: frozenJob) {
            guard let authoritative = try MeetingMinutesExecutionState.load(store: store, id: id,
                                                                              job: overviewJob),
                  authoritative == ledger else { throw Failure.stalePublication }
            // The prior accepted revision stays authoritative until the full
            // rewrite is validated. Publication is fenced by the frozen job
            // and durable outcome, not by publishing an intermediate base.
            if let accepted = store.loadAcceptedMinutes(id: id),
               Self.acceptedMatches(accepted, minutes: rewritten, job: frozenJob) {
                return rewritten
            }
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
                                            input: MeetingMinutesSummaryPass.Input,
                                            domain: String = "reconciliation-tree-v1") throws -> String {
        struct Fingerprint: Encodable { let domain: String; let original: String; let envelopeHashes: [String]; let envelope: MeetingMinutesEnvelope; let base: MeetingMinutes; let input: MeetingMinutesSummaryPass.Input }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let hashes = try envelopes.map { SHA256.hash(data: try encoder.encode($0)).map { String(format: "%02x", $0) }.joined() }
        return SHA256.hash(data: try encoder.encode(Fingerprint(domain: domain, original: original, envelopeHashes: hashes, envelope: envelope, base: base, input: input))).map { String(format: "%02x", $0) }.joined()
    }
}
