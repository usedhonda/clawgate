import Foundation

/// Dedicated bounded execution, deliberately not wired to the live PetModel.
/// Each step reserves before dispatch, recovers existing owners read-only and
/// processes every response independently. No implicit retries or chat fallback.
actor MeetingMinutesExecutor {
    enum Failure: Error { case busy, invalidPart }
    struct Progress {
        let completed: Int
        let total: Int
        let live: Int
        let failed: Int
        let unresolvedIndices: [Int]
    }
    typealias Send = (MinutesExecutionSendParams) async throws -> MinutesExecutionAck
    typealias Read = (MinutesExecutionSendParams) async throws -> MinutesExecutionRead
    private enum Event {
        case ack(MeetingMinutesExecutionState.Dispatch, MinutesExecutionAck)
        case read(MeetingMinutesExecutionState.Dispatch, MinutesExecutionRead)
        case unavailable(Int)
    }
    private let store: MeetingStore
    private let id: String
    private let job: MeetingMinutesJob
    private let sessionKey: String
    private let send: Send
    private let read: Read
    private var ledger: MeetingMinutesExecutionState
    private var busy = false

    init(job: MeetingMinutesJob, store: MeetingStore, id: String, sessionKey: String,
         send: @escaping Send, read: @escaping Read) throws {
        self.job = job; self.store = store; self.id = id; self.sessionKey = sessionKey
        self.send = send; self.read = read
        ledger = try MeetingMinutesExecutionState.load(store: store, id: id, job: job)
            ?? MeetingMinutesExecutionState(job: job)
    }

    /// Production scheduling/activation must be supplied only after the shared
    /// Gateway gate. Transport failures leave durable owners for a later read.
    func step() async throws -> Progress {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        let recovering = ledger.recoverableDispatches
        var fresh: [MeetingMinutesExecutionState.Dispatch] = []
        // A confirmed failed part requires explicit owner action. It must not
        // silently retry or keep filling subsequent work while recovery fails.
        if !ledger.parts.contains(where: { $0.status == .failed }) {
            for p in ledger.parts.filter({ $0.status == .pending }).prefix(2 - recovering.count) {
                let message = try MeetingMinutesPrompt.buildMessage(envelope: job.envelopes[p.index])
                fresh.append(try ledger.reserve(index: p.index, sessionKey: sessionKey, message: message, store: store, id: id))
            }
        }
        let sender = send, reader = read
        var unresolved: [Int] = []
        var persistenceError: Error?
        await withTaskGroup(of: Event.self) { group in
            for d in recovering {
                group.addTask {
                    do { return .read(d, try await reader(d.request)) }
                    catch { return .unavailable(d.index) }
                }
            }
            for d in fresh {
                group.addTask {
                    do { return .ack(d, try await sender(d.request)) }
                    catch { return .unavailable(d.index) }
                }
            }
            for await event in group {
                // A storage failure poisons this writer; preserve every owner
                // and reopen rather than trying another stale write.
                if persistenceError != nil { continue }
                do {
                    switch event {
                    case .unavailable(let index): unresolved.append(index)
                    case .ack(let d, let ack): try ledger.acknowledge(d, ack: ack, store: store, id: id)
                    case .read(let d, let result):
                        if result.result == .expired || result.result == .notFound {
                            unresolved.append(d.index); continue
                        }
                        guard result.binding?.matches(d.request) == true else {
                            unresolved.append(d.index); continue
                        }
                        if ledger.parts[d.index].status == .submitting {
                            try ledger.reconcile(d, read: result, store: store, id: id)
                        }
                        switch result.result {
                        case .pending: break
                        case .answer(let text):
                            let envelope = job.envelopes[d.index]
                            let outcome: MeetingMinutesExecutionState.Outcome
                            do {
                                let minutes = try MeetingMinutesParser.parse(text,
                                    validSegmentIds: Set(envelope.segments.map(\.id)),
                                    validMaterialIds: Set((envelope.supplementalMaterials ?? []).flatMap(\.sections).map(\.id)))
                                outcome = minutes.map(MeetingMinutesExecutionState.Outcome.answer) ?? .insufficientEvidence
                            } catch {
                                try ledger.failTerminal(d, runId: d.idempotencyKey, code: "invalid_answer", retryable: false, store: store, id: id)
                                continue
                            }
                            try ledger.complete(d, runId: d.idempotencyKey, outcome: outcome, store: store, id: id)
                        case .failed(let code, let retriable):
                            try ledger.failTerminal(d, runId: d.idempotencyKey, code: code, retryable: retriable, store: store, id: id)
                        case .aborted:
                            try ledger.failTerminal(d, runId: d.idempotencyKey, code: "aborted", retryable: false, store: store, id: id)
                        case .expired, .notFound: break
                        }
                    }
                } catch { persistenceError = error }
            }
        }
        if let persistenceError { throw persistenceError }
        return Progress(completed: ledger.parts.filter { $0.status == .completed }.count,
                        total: ledger.parts.count,
                        live: ledger.recoverableDispatches.count,
                        failed: ledger.parts.filter { $0.status == .failed }.count,
                        unresolvedIndices: unresolved.sorted())
    }

    /// Commit only the current complete revision. The accepted bundle is the
    /// read authority; the returned complete job feeds overview generation.
    func finalize(record: MeetingRecord) throws -> MeetingMinutesExecutionFinalizer.Result {
        guard !busy else { throw Failure.busy }
        return try MeetingMinutesExecutionFinalizer.finalize(ledger: ledger, frozenJob: job,
                                                              record: record, store: store, id: id)
    }

    /// Source-order outcomes, not completion-order append. Accepted minutes/job
    /// remain untouched until the future live caller performs validated merge.
    func orderedOutcomes() -> [MeetingMinutesExecutionState.Outcome?] { ledger.orderedOutcomes }
}
