import Foundation
import CryptoKit
import Darwin

/// Durable, indexed execution ledger for the (future) bounded minutes runner.
/// This is deliberately a sidecar: `MeetingMinutesJob` remains the accepted
/// sequential-prefix checkpoint and is never rewritten by this type.
struct MeetingMinutesExecutionState: Codable, Equatable {
    static let currentVersion = 2
    static let legacyFileName = "minutes-execution-state.json"

    enum Status: String, Codable { case pending, submitting, running, completed, failed, admissionRejected }
    enum Outcome: Codable, Equatable {
        case insufficientEvidence
        case answer(MeetingMinutes)
        private enum CodingKeys: String, CodingKey { case kind, minutes }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "insufficientEvidence": self = .insufficientEvidence
            case "answer": self = .answer(try c.decode(MeetingMinutes.self, forKey: .minutes))
            default: throw LedgerError.malformed("unknown outcome")
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .insufficientEvidence: try c.encode("insufficientEvidence", forKey: .kind)
            case .answer(let minutes):
                try c.encode("answer", forKey: .kind); try c.encode(minutes, forKey: .minutes)
            }
        }
    }
    struct Part: Codable, Equatable {
        let index: Int
        let envelopeHash: String
        var request: MinutesExecutionSendParams?
        var requestFingerprint: String?
        var executionBinding: MinutesExecutionBinding?
        var status: Status
        var attempt: Int
        var idempotencyKey: String?
        var sessionKey: String?
        var runId: String?
        var reason: String?
        var retryable: Bool
        var outcome: Outcome?
    }
    struct Dispatch: Equatable {
        let index: Int; let attempt: Int; let idempotencyKey: String
        let sessionKey: String; let request: MinutesExecutionSendParams
    }
    enum LedgerError: Error { case malformed(String), mismatch, invalidTransition, staleOwner, tooManyLiveParts, notRetryable, persistence(Error), storageFailed, staleWriter }

    let version: Int
    let fingerprint: String
    private(set) var parts: [Part]
    private var persistedHash: String? = nil
    private var storageFailed = false
    private enum CodingKeys: String, CodingKey { case version, fingerprint, parts }

    init(job: MeetingMinutesJob) throws {
        guard job.completed.count <= job.envelopes.count else { throw LedgerError.malformed("completed exceeds envelopes") }
        let prefix = job.completed.count
        let values = try job.envelopes.enumerated().map { index, envelope -> Part in
            let outcome: Outcome? = index < prefix ? (job.completed[index].map(Outcome.answer) ?? .insufficientEvidence) : nil
            return Part(index: index, envelopeHash: try Self.hash(envelope),
                        request: nil, requestFingerprint: nil, executionBinding: nil, status: index < prefix ? .completed : .pending, attempt: 0, idempotencyKey: nil, sessionKey: nil, runId: nil,
                        reason: nil, retryable: false, outcome: outcome)
        }
        self.init(version: Self.currentVersion, fingerprint: job.fingerprint, parts: values)
    }

    private init(version: Int, fingerprint: String, parts: [Part]) {
        self.version = version; self.fingerprint = fingerprint; self.parts = parts
    }

    static func hash(_ envelope: MeetingMinutesEnvelope) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(envelope) } catch { throw LedgerError.malformed("envelope encoding failed") }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(store: MeetingStore, id: String, job: MeetingMinutesJob) throws -> MeetingMinutesExecutionState? {
        guard job.completed.count <= job.envelopes.count else { throw LedgerError.mismatch }
        let dir = store.directory(for: id)
        // Never silently ignore an unversioned legacy owner at activation.
        guard try readPrivateFile(dir.appendingPathComponent(legacyFileName)) == nil else { throw LedgerError.mismatch }
        let url = try fileURL(store: store, id: id, job: job)
        guard let data = try readPrivateFile(url) else { return nil }
        var decoded: MeetingMinutesExecutionState
        do { decoded = try JSONDecoder().decode(Self.self, from: data) } catch { throw LedgerError.malformed("decode failed") }
        guard decoded.version == currentVersion, decoded.fingerprint == job.fingerprint,
              decoded.parts.count == job.envelopes.count,
              decoded.parts.map(\.index) == Array(job.envelopes.indices),
              zip(decoded.parts, job.envelopes).allSatisfy({ (try? hash($0.1)) == $0.0.envelopeHash }),
              decoded.validInvariants else {
            throw LedgerError.mismatch
        }
        for index in job.completed.indices {
            let original = job.completed[index].map(Outcome.answer) ?? .insufficientEvidence
            guard decoded.parts[index].status == .completed, decoded.parts[index].outcome == original else {
                throw LedgerError.mismatch
            }
        }
        decoded.persistedHash = digest(data)
        return decoded
    }

    static func fileURL(store: MeetingStore, id: String, job: MeetingMinutesJob) throws -> URL {
        let hashes = try job.envelopes.map(hash)
        return store.directory(for: id).appendingPathComponent(try revisionFileName(fingerprint: job.fingerprint, hashes: hashes))
    }

    private static func revisionFileName(fingerprint: String, hashes: [String]) throws -> String {
        let data = try JSONEncoder().encode([fingerprint] + hashes)
        return "minutes-execution-" + digest(data) + ".json"
    }

    mutating func save(store: MeetingStore, id: String) throws {
        try commit(self, store: store, id: id)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readPrivateFile(_ url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw LedgerError.storageFailed
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else {
            throw LedgerError.malformed("sidecar permissions")
        }
        return try handle.readToEnd() ?? Data()
    }

    private func persist(_ candidate: Self, store: MeetingStore, id: String) throws -> String {
        guard candidate.validInvariants else { throw LedgerError.malformed("invalid state") }
        let dir = store.directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(dir.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw LedgerError.storageFailed }
        guard try Self.readPrivateFile(dir.appendingPathComponent(Self.legacyFileName)) == nil else { throw LedgerError.mismatch }
        let url = dir.appendingPathComponent(try Self.revisionFileName(fingerprint: fingerprint, hashes: parts.map(\.envelopeHash)))
        let lock = open(dir.appendingPathComponent(".minutes-execution.lock").path,
                        O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw LedgerError.storageFailed }
        defer { close(lock) }
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw LedgerError.storageFailed }
        defer { flock(lock, LOCK_UN) }
        // A copied value or a second process cannot overwrite a newer attempt.
        let currentHash = try Self.readPrivateFile(url).map(Self.digest)
        guard currentHash == persistedHash else { throw LedgerError.staleWriter }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(candidate)
        let tmp = dir.appendingPathComponent(".minutes-execution-\(UUID().uuidString).tmp")
        let descriptor = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LedgerError.storageFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: tmp) }
        try file.write(contentsOf: data)
        guard fsync(descriptor) == 0, rename(tmp.path, url.path) == 0 else { throw LedgerError.storageFailed }
        let directory = open(dir.path, O_RDONLY | O_NOFOLLOW)
        guard directory >= 0 else { throw LedgerError.storageFailed }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw LedgerError.storageFailed }
        return Self.digest(data)
    }

    /// Writes the candidate first; failed persistence leaves this value unchanged.
    private mutating func commit(_ candidate: MeetingMinutesExecutionState, store: MeetingStore, id: String) throws {
        guard !storageFailed else { throw LedgerError.storageFailed }
        do {
            let hash = try persist(candidate, store: store, id: id)
            self = candidate
            persistedHash = hash
        } catch {
            // A post-rename failure may have committed bytes. Do not attempt
            // another write from stale memory; reload the authoritative file.
            storageFailed = true
            throw error
        }
    }

    private func owner(_ p: Part, index: Int, attempt: Int, key: String, sessionKey: String) throws {
        guard p.index == index, p.attempt == attempt, p.idempotencyKey == key, p.sessionKey == sessionKey else { throw LedgerError.staleOwner }
    }

    mutating func reserve(index: Int, sessionKey: String, message: String, store: MeetingStore, id: String) throws -> Dispatch {
        try reserveAttempt(index: index, sessionKey: sessionKey, message: message, retry: false, store: store, id: id)
    }

    private mutating func reserveAttempt(index: Int, sessionKey: String, message: String, retry: Bool, store: MeetingStore, id: String) throws -> Dispatch {
        guard parts.indices.contains(index), Self.validSession(sessionKey) else { throw LedgerError.invalidTransition }
        guard parts.filter({ $0.status == .submitting || $0.status == .running }).count < 2 else { throw LedgerError.tooManyLiveParts }
        let old = parts[index]
        guard retry ? (old.status == .failed && old.retryable) : old.status == .pending,
              old.attempt < Int.max else { throw LedgerError.invalidTransition }
        if retry {
            guard let original = old.request, original.sessionKey == sessionKey,
                  original.message.utf8.elementsEqual(message.utf8) else { throw LedgerError.invalidTransition }
        }
        var candidate = self
        let key = UUID().uuidString
        let request = MinutesExecutionSendParams(sessionKey: sessionKey, message: message, idempotencyKey: key)
        let requestFingerprint = try request.requestFingerprint()
        candidate.parts[index].status = .submitting; candidate.parts[index].attempt += 1
        candidate.parts[index].request = request
        candidate.parts[index].requestFingerprint = requestFingerprint
        candidate.parts[index].executionBinding = nil
        candidate.parts[index].idempotencyKey = key; candidate.parts[index].sessionKey = sessionKey
        candidate.parts[index].runId = nil; candidate.parts[index].reason = nil; candidate.parts[index].retryable = false; candidate.parts[index].outcome = nil
        try commit(candidate, store: store, id: id)
        return Dispatch(index: index, attempt: candidate.parts[index].attempt, idempotencyKey: key, sessionKey: sessionKey, request: request)
    }

    /// Retry is intentionally separate from initial reservation: only a
    /// confirmed terminal, retryable failure may create a new owner key.
    mutating func retry(index: Int, sessionKey: String, message: String, store: MeetingStore, id: String) throws -> Dispatch {
        guard parts.indices.contains(index), parts[index].status == .failed, parts[index].retryable else { throw LedgerError.notRetryable }
        return try reserveAttempt(index: index, sessionKey: sessionKey, message: message, retry: true, store: store, id: id)
    }

    mutating func acknowledge(_ dispatch: Dispatch, ack: MinutesExecutionAck, store: MeetingStore, id: String) throws {
        guard parts.indices.contains(dispatch.index), ack.runId == dispatch.idempotencyKey,
              ack.sessionKey == dispatch.sessionKey,
              ack.binding.requestFingerprint == (try dispatch.request.requestFingerprint()) else { throw LedgerError.invalidTransition }
        let old = parts[dispatch.index]; try owner(old, index: dispatch.index, attempt: dispatch.attempt, key: dispatch.idempotencyKey, sessionKey: dispatch.sessionKey)
        guard old.status == .submitting, old.requestFingerprint == (try dispatch.request.requestFingerprint()) else { throw LedgerError.invalidTransition }
        var candidate = self; candidate.parts[dispatch.index].status = .running; candidate.parts[dispatch.index].runId = ack.runId
        candidate.parts[dispatch.index].executionBinding = ack.binding
        try commit(candidate, store: store, id: id)
    }

    mutating func reconcile(_ dispatch: Dispatch, read: MinutesExecutionRead, store: MeetingStore, id: String) throws {
        guard parts.indices.contains(dispatch.index), read.result != .expired, read.result != .notFound, let binding = read.binding,
              binding.requestFingerprint == (try dispatch.request.requestFingerprint()) else { throw LedgerError.invalidTransition }
        let old = parts[dispatch.index]; try owner(old, index: dispatch.index, attempt: dispatch.attempt, key: dispatch.idempotencyKey, sessionKey: dispatch.sessionKey)
        guard old.status == .submitting, old.requestFingerprint == (try dispatch.request.requestFingerprint()) else { throw LedgerError.invalidTransition }
        var candidate = self; candidate.parts[dispatch.index].status = .running; candidate.parts[dispatch.index].runId = dispatch.idempotencyKey
        candidate.parts[dispatch.index].executionBinding = binding
        try commit(candidate, store: store, id: id)
    }

    mutating func complete(_ dispatch: Dispatch, runId: String, outcome: Outcome, store: MeetingStore, id: String) throws {
        try transitionTerminal(dispatch, runId: runId, status: .completed, outcome: outcome, reason: nil, retryable: false, store: store, id: id)
    }

    mutating func failTerminal(_ dispatch: Dispatch, runId: String, code: String, retryable: Bool, store: MeetingStore, id: String) throws {
        guard Self.validCode(code) else { throw LedgerError.invalidTransition }
        try transitionTerminal(dispatch, runId: runId, status: .failed, outcome: nil, reason: code, retryable: retryable, store: store, id: id)
    }

    /// Persist a definitive server rejection that happened before admission.
    /// The reserved request/key remain immutable; no binding or run id is
    /// invented, and this status is never retryable.
    mutating func rejectAdmission(_ dispatch: Dispatch, store: MeetingStore, id: String) throws {
        guard parts.indices.contains(dispatch.index) else { throw LedgerError.staleOwner }
        let old = parts[dispatch.index]
        try owner(old, index: dispatch.index, attempt: dispatch.attempt,
                  key: dispatch.idempotencyKey, sessionKey: dispatch.sessionKey)
        guard old.status == .submitting,
              old.requestFingerprint == (try dispatch.request.requestFingerprint()),
              old.runId == nil, old.executionBinding == nil else {
            throw LedgerError.invalidTransition
        }
        var candidate = self
        candidate.parts[dispatch.index].status = .admissionRejected
        candidate.parts[dispatch.index].reason = "admission_rejected"
        candidate.parts[dispatch.index].retryable = false
        try commit(candidate, store: store, id: id)
    }

    private mutating func transitionTerminal(_ dispatch: Dispatch, runId: String, status: Status, outcome: Outcome?, reason: String?, retryable: Bool, store: MeetingStore, id: String) throws {
        guard parts.indices.contains(dispatch.index), let currentRun = parts[dispatch.index].runId, currentRun == runId else { throw LedgerError.staleOwner }
        let old = parts[dispatch.index]; try owner(old, index: dispatch.index, attempt: dispatch.attempt, key: dispatch.idempotencyKey, sessionKey: dispatch.sessionKey)
        guard old.status == .running, old.requestFingerprint == (try dispatch.request.requestFingerprint()) else { throw LedgerError.invalidTransition }
        var candidate = self; candidate.parts[dispatch.index].status = status; candidate.parts[dispatch.index].outcome = outcome; candidate.parts[dispatch.index].reason = reason; candidate.parts[dispatch.index].retryable = retryable
        try commit(candidate, store: store, id: id)
    }

    var orderedOutcomes: [Outcome?] { parts.sorted { $0.index < $1.index }.map(\.outcome) }
    var nextIndices: [Int] { parts.filter { $0.status == .pending || ($0.status == .failed && $0.retryable) }.map(\.index) }
    var hasLiveParts: Bool { parts.contains { $0.status == .submitting || $0.status == .running } }
    var recoverableDispatches: [Dispatch] {
        parts.compactMap { p in
            guard (p.status == .submitting || p.status == .running), let request = p.request,
                  let key = p.idempotencyKey, let session = p.sessionKey else { return nil }
            return Dispatch(index: p.index, attempt: p.attempt, idempotencyKey: key, sessionKey: session, request: request)
        }
    }

    private var validInvariants: Bool {
        guard parts.map(\.index) == Array(parts.indices), parts.filter({ $0.status == .submitting || $0.status == .running }).count <= 2 else { return false }
        let keys = parts.compactMap(\.idempotencyKey)
        guard Set(keys).count == keys.count else { return false }
        return parts.allSatisfy { p in
            guard p.attempt >= 0, p.envelopeHash.count == 64, p.envelopeHash.allSatisfy(\.isHexDigit) else { return false }
            let ownerValid = p.attempt > 0 && p.idempotencyKey.flatMap(UUID.init(uuidString:)) != nil &&
                p.sessionKey.map(Self.validSession) == true
            let noError = p.reason == nil && !p.retryable
            switch p.status {
            case .pending: return p.attempt == 0 && p.idempotencyKey == nil && p.sessionKey == nil && p.runId == nil && p.outcome == nil && noError && p.request == nil && p.requestFingerprint == nil && p.executionBinding == nil
            case .submitting: return ownerValid && p.runId == nil && p.outcome == nil && noError && requestValid(p) && p.executionBinding == nil
            case .running: return ownerValid && p.runId == p.idempotencyKey && p.outcome == nil && noError && requestValid(p) && bindingValid(p)
            case .completed:
                let inherited = p.attempt == 0 && p.idempotencyKey == nil && p.sessionKey == nil && p.runId == nil && p.request == nil && p.requestFingerprint == nil && p.executionBinding == nil
                return (inherited || (ownerValid && p.runId == p.idempotencyKey && requestValid(p) && bindingValid(p))) && p.outcome != nil && noError
            case .failed: return ownerValid && p.runId == p.idempotencyKey && p.reason.map(Self.validCode) == true && p.outcome == nil && requestValid(p) && bindingValid(p)
            case .admissionRejected:
                return ownerValid && p.runId == nil && p.reason == "admission_rejected" && !p.retryable &&
                    p.outcome == nil && requestValid(p) && p.executionBinding == nil
            }
        }
    }

    private static func validSession(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private func bindingValid(_ p: Part) -> Bool {
        guard let request = p.request, let binding = p.executionBinding else { return false }
        return binding.matches(request)
    }

    private func requestValid(_ p: Part) -> Bool {
        guard let request = p.request, let fingerprint = p.requestFingerprint,
              request.sessionKey == p.sessionKey, request.idempotencyKey == p.idempotencyKey,
              (try? request.requestFingerprint()) == fingerprint else { return false }
        return true
    }

    private static func validCode(_ code: String) -> Bool {
        !code.isEmpty && code.utf8.count <= 128 && code.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}
