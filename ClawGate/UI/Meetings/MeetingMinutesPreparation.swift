import Foundation

enum MeetingMinutesPreparation {
    enum Failure: Error {
        case changed
        case cancelled
        case noTranscript
        case materialLimit
    }

    final class Ticket {
        let requestedAt: Date?
        private let lock = NSLock()
        private var cancelled = false

        init(requestedAt: Date?) { self.requestedAt = requestedAt }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func check() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw Failure.cancelled }
        }
    }

    struct Input {
        let record: MeetingRecord
        let store: MeetingStore
        let sessionsRoot: URL
        let material: MeetingGoogleMaterials.Snapshot?
        let transcript: ((MeetingRecord) -> [TranscriptSegment])?
        let preservingMaterials: Bool
        let refreshPreparedInput: Bool
        let regenerate: Bool
        let forceFull: Bool
    }

    struct Output {
        let owned: Bool
        let files: [String: String]
    }

    static func hasIndexedOwner(store: MeetingStore, id: String, job: MeetingMinutesJob?) -> Bool {
        do {
            if let job { return try MeetingMinutesExecutionState.load(store: store, id: id, job: job) != nil }
            let directory = store.directory(for: id)
            guard FileManager.default.fileExists(atPath: directory.path) else { return false }
            return try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
                $0.hasPrefix("minutes-execution-") && $0.hasSuffix(".json")
            }
        } catch { return true }
    }

    static func run(_ input: Input, ticket: Ticket) throws -> Output {
        try ticket.check()
        let record = input.record
        let store = input.store
        guard store.load(id: record.id) == record else { throw Failure.changed }
        let directory = store.directory(for: record.id)
        let files = try MeetingMinutesSourceRevision.files(in: directory)
        let jobURL = directory.appendingPathComponent("minutes-job.json")
        let previousData = FileManager.default.fileExists(atPath: jobURL.path) ? try Data(contentsOf: jobURL) : nil
        let previous = try previousData.map { try JSONDecoder().decode(MeetingMinutesJob.self, from: $0) }
        let pilot = MeetingMinutesPilot.load()
        if hasIndexedOwner(store: store, id: record.id, job: previous)
            || previous.map({ pilot?.matches(store: store, id: record.id, job: $0) == true }) == true {
            return Output(owned: true, files: files)
        }
        try ticket.check()
        let updated: MeetingMinutesJob
        var sourceRevision: String?
        var end: Double?
        let anchor = Date().timeIntervalSince1970
        func validateInput() throws {
            try ticket.check()
            guard store.load(id: record.id) == record,
                  try MeetingMinutesSourceRevision.files(in: directory) == files else { throw Failure.changed }
            if let end, let sourceRevision {
                guard AmbientController.trimmedEnd(of: record, against: store.all(), now: anchor) == end,
                      try MeetingMinutesSourceRevision.ambientRevision(record: record, files: files,
                        end: end, sessionsRoot: input.sessionsRoot) == sourceRevision else { throw Failure.changed }
            }
            try ticket.check()
        }
        if !input.regenerate, record.minutesState == "pending", var frozen = previous,
           !input.refreshPreparedInput || !frozen.completed.isEmpty {
            if let requestedAt = ticket.requestedAt { frozen.userRequestedAt = requestedAt }
            updated = frozen
        } else {
            let boundary = AmbientController.trimmedEnd(of: record, against: store.all(), now: anchor)
            end = boundary
            sourceRevision = try MeetingMinutesSourceRevision.ambientRevision(record: record, files: files,
                end: boundary, sessionsRoot: input.sessionsRoot)
            try ticket.check()
            let local = record.source == "calendar" ? (store.loadBackfill(id: record.id) ?? []) : (input.transcript?(record) ?? [])
            let material = input.material ?? record.materialCandidateID.flatMap { MeetingGoogleMaterials.load(candidateID: $0) }
            var envelope = try PetModel.minutesEnvelope(for: record, store: store, local: local,
                material: material, checkingCancellation: { try ticket.check() })
            if !input.regenerate, record.minutesState == "pending" || input.preservingMaterials,
               let previous { envelope.supplementalMaterials = previous.allSupplementalMaterials }
            guard !envelope.segments.isEmpty else {
                try validateInput()
                throw Failure.noTranscript
            }
            guard (envelope.supplementalMaterials ?? []).flatMap(\.sections).reduce(0, { $0 + $1.text.count }) <= 200_000 else {
                try validateInput()
                throw Failure.materialLimit
            }
            try ticket.check()
            if input.regenerate {
                updated = MeetingMinutesJob.updating(envelope, previous: input.forceFull ? nil : previous,
                    requestedAt: ticket.requestedAt ?? Date())
            } else {
                let fingerprint = MeetingMinutesJob.fingerprint(envelope)
                if let previous, previous.fingerprint == fingerprint {
                    var refreshed = previous.refreshingMetadata(from: envelope)
                    if let requestedAt = ticket.requestedAt { refreshed.userRequestedAt = requestedAt }
                    updated = refreshed
                } else {
                    updated = MeetingMinutesJob(fingerprint: fingerprint, envelopes: MeetingMinutes.chunked(envelope),
                        completed: [], supplementalSnapshot: envelope.supplementalMaterials,
                        userRequestedAt: ticket.requestedAt)
                }
            }
        }
        try ticket.check()
        try updated.saveReplacing(store: store, id: record.id, expected: previousData) {
            try validateInput()
            guard !hasIndexedOwner(store: store, id: record.id, job: previous) else { throw Failure.changed }
            if let previous, MeetingMinutesPilot.load()?.matches(store: store, id: record.id, job: previous) == true {
                throw Failure.changed
            }
            try ticket.check()
        }
        return Output(owned: false, files: try MeetingMinutesSourceRevision.files(in: directory))
    }
}
