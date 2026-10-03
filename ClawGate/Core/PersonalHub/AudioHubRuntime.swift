import Foundation
import Darwin
import CryptoKit

/// Owner-supplied activation boundary for the native audio producer.
/// This is deliberately private configuration: an absent file means the route
/// is unconfigured, never "start at EOF" or "scan all sessions".
struct AudioHubActivationManifest: Codable, Equatable {
    struct Session: Codable, Equatable {
        let sessionID: String
        let initial: AudioHubRawTranscriptReader.Checkpoint
        let prefixSHA256: String
    }

    struct CommittedOriginal: Codable, Equatable {
        struct SourceChunk: Codable, Equatable {
            let id: String
            let source: String
            let startedAt: Double
            let endedAt: Double?
        }
        let meetingID: String
        let chunkID: String
        let sha256: String
        let byteLength: Int64
        let sourceChunk: SourceChunk
    }

    let version: Int
    let maxMetadataBytes: Int
    let maxControlBytes: Int
    let sessions: [Session]
    let committedOriginals: [CommittedOriginal]

    static let approvedMetadataBytes = 128 * 1024 * 1024
    static let approvedControlBytes = 16 * 1024 * 1024
}

extension AudioHubSelectedMeetingAdmission {
    struct ManifestAsset: Codable, Equatable {
        let row: MeetingAudioArchive.Chunk
        let original: AudioHubOutbox.OriginalReference

        var asset: Asset { Asset(row: row, original: original) }
    }
}

/// Bounded coordinator. It only admits sources named by an explicit manifest;
/// callers decide when to invoke `scanOnce` or delivery. No network task starts
/// from construction or recovery, and one coordinator serializes mutation.
final class AudioHubRuntime {
    enum Failure: Swift.Error, Equatable {
        case unconfigured
        case malformedManifest
        case duplicateSource
        case invalidPath
        case busy
    }

    private let sessionsRoot: URL
    private let meetingsRoot: URL
    private let runtimeRoot: URL
    private let manifest: AudioHubActivationManifest
    private let outbox: AudioHubOutbox
    private let control: AudioHubControlStore
    private let provisionLoader: () throws -> HubProducerProvision?
    private var scanners: [String: AudioHubTranscriptScanner] = [:]
    private let lock = NSLock()
    private let schedulingLock = NSLock()
    private var deliveryInFlight = false
    private var worker: Task<Void, Never>?
    private var workerAgain = false
    private var stopped = false
    private var failureCode: String?
    private var registrationFailure: String?
    var lastFailure: String? { schedulingLock.lock(); defer { schedulingLock.unlock() }; return registrationFailure ?? failureCode }

    /// Returns nil when the owner has not installed an activation manifest.
    init?(manifestURL: URL, sessionsRoot: URL, meetingsRoot: URL,
          runtimeRoot: URL,
          provisionLoader: @escaping () throws -> HubProducerProvision? = { try HubProducerProvision.load(source: "clawgate") }) throws {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let descriptor = open(manifestURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.malformedManifest }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 256 * 1024 else {
            try? file.close(); throw Failure.malformedManifest
        }
        let data = try file.read(upToCount: 256 * 1024 + 1) ?? Data()
        try? file.close()
        guard data.count <= 256 * 1024,
              let value = try? JSONDecoder().decode(AudioHubActivationManifest.self, from: data),
              Self.valid(value), value.maxControlBytes > data.count else { throw Failure.malformedManifest }
        self.manifest = value
        self.sessionsRoot = sessionsRoot
        self.meetingsRoot = meetingsRoot
        self.runtimeRoot = runtimeRoot
        let outbox = try AudioHubOutbox(directory: runtimeRoot.appendingPathComponent("outbox"),
                                        maxMetadataBytes: value.maxMetadataBytes)
        self.outbox = outbox
        self.control = try AudioHubControlStore(directory: runtimeRoot.appendingPathComponent("control"),
                                                sourceUUID: outbox.sourceUUID,
                                                // The manifest is persisted configuration in the
                                                // same bounded runtime state budget.
                                                maxControlBytes: value.maxControlBytes - data.count)
        self.provisionLoader = provisionLoader
    }

    static func valid(_ manifest: AudioHubActivationManifest) -> Bool {
        guard manifest.version == 2,
              manifest.maxMetadataBytes == AudioHubActivationManifest.approvedMetadataBytes,
              manifest.maxControlBytes == AudioHubActivationManifest.approvedControlBytes,
              !manifest.sessions.isEmpty || !manifest.committedOriginals.isEmpty else { return false }
        guard Set(manifest.sessions.map(\.sessionID)).count == manifest.sessions.count,
              manifest.sessions.allSatisfy({ validSession($0) }) else { return false }
        guard Set(manifest.committedOriginals.map { "\($0.meetingID)/\($0.chunkID)" }).count == manifest.committedOriginals.count,
              manifest.committedOriginals.allSatisfy({ validOriginal($0) }) else { return false }
        return true
    }

    private static func validSession(_ item: AudioHubActivationManifest.Session) -> Bool {
        let c = item.initial
        guard !item.sessionID.isEmpty, item.sessionID != ".", item.sessionID != "..",
              Self.validComponent(item.sessionID), c.snapshot != nil,
              validHash(item.prefixSHA256),
              c.offset <= UInt64(Int64.max), c.physicalLine <= UInt64(Int.max) else { return false }
        return true
    }

    private static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.unicodeScalars.contains {
            $0 == "/" || $0 == "\\" || $0 == ":" || CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func validOriginal(_ item: AudioHubActivationManifest.CommittedOriginal) -> Bool {
        validComponent(item.meetingID) && validComponent(item.chunkID) && item.chunkID == item.sourceChunk.id &&
            validHash(item.sha256) && item.byteLength > 0 && !item.sourceChunk.source.isEmpty &&
            item.sourceChunk.startedAt.isFinite && (item.sourceChunk.endedAt?.isFinite ?? true)
    }

    /// Recover only the listed scanner checkpoints and selected index rows.
    /// This is admission/recovery, not delivery or activation of networking.
    func recover() throws {
        lock.lock(); defer { lock.unlock() }
        do {
            for entry in manifest.sessions {
                if scanners[entry.sessionID] != nil { continue }
                try installBaseline(entry)
            }
            for (id, scan) in try control.registeredScans() where scanners[id] == nil {
                scanners[id] = try makeScanner(id, initial: scan.initial)
            }
            // Committed originals are coverage only, never delivery work.
            // Only explicit writer-registered future commits enter this loop.
            let checkpoints = try control.checkpoints()
            var selectedFailure: Error?
            for registration in try control.selectedRegistrations() {
                do {
                let waiting = registration.assets.filter {
                    !AudioHubSelectedMeetingAdmission.isAdmitted(meetingID: registration.meetingID,
                        asset: $0.asset, checkpoints: checkpoints)
                }
                if waiting.isEmpty { continue }
                let indexData = try Self.readIndex("meetings/\(registration.meetingID)/audio/index.json", under: meetingsRoot,
                                                   maxBytes: manifest.maxControlBytes)
                guard !indexData.isEmpty else { throw Failure.invalidPath }
                let committed = try JSONDecoder().decode([MeetingAudioArchive.Chunk].self, from: indexData)
                guard Set(committed.map(\.id)).count == committed.count,
                      waiting.allSatisfy({ asset in committed.contains(asset.row) }) else {
                    throw Failure.invalidPath
                }
                _ = try AudioHubSelectedMeetingAdmission.admit(
                    meetingID: registration.meetingID, indexData: registration.indexData,
                    assets: waiting.map(\.asset),
                    selectedIDs: Set(waiting.map { $0.row.id }),
                    originalsRoot: meetingsRoot, outbox: outbox, control: control)
                } catch {
                    switch error as? AudioHubOriginalReader.Error {
                    case .missingOriginal:
                        try control.recordSelectedGap(registration: registration, reason: "source_original_missing")
                    case .contentMismatch, .sourceChanged:
                        try control.recordSelectedGap(registration: registration, reason: "source_original_changed")
                    default: break
                    }
                    if selectedFailure == nil { selectedFailure = error }
                }
            }
            if let selectedFailure { throw selectedFailure }
            recordFailure(nil)
        } catch {
            recordFailure("source_admission_failed")
            throw error
        }
    }

    private func makeScanner(_ id: String, initial: AudioHubRawTranscriptReader.Checkpoint) throws -> AudioHubTranscriptScanner {
        try AudioHubTranscriptScanner(sessionsRoot: sessionsRoot, sessionID: id,
            initialCheckpoint: initial, control: control, outbox: outbox,
            maxReadBytes: 1 * 1024 * 1024, maxLineBytes: 512 * 1024)
    }

    private func installBaseline(_ entry: AudioHubActivationManifest.Session) throws {
        try AudioHubBaselineReader.verify(sessionsRoot: sessionsRoot, entry: entry)
        scanners[entry.sessionID] = try makeScanner(entry.sessionID, initial: entry.initial)
    }

    /// Called under the raw writer's file lock, before any new bytes. Only an
    /// empty, actual source inode may create a previously unregistered scanner.
    func registerRawWriter(sessionID: String, snapshot: AudioHubRawTranscriptReader.Snapshot) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.validComponent(sessionID) else { throw Failure.invalidPath }
        do {
            if let entry = manifest.sessions.first(where: { $0.sessionID == sessionID }) {
                if scanners[sessionID] == nil { try installBaseline(entry) }
            } else if let existing = try control.registeredScans()[sessionID] {
                if scanners[sessionID] == nil { scanners[sessionID] = try makeScanner(sessionID, initial: existing.initial) }
            } else {
                guard snapshot.length == 0 else { throw Failure.unconfigured }
                scanners[sessionID] = try makeScanner(sessionID,
                    initial: .init(offset: 0, physicalLine: 0, snapshot: snapshot))
            }
            let scan = try control.scan(sessionID: sessionID)
            guard scan.initial.snapshot?.device == snapshot.device,
                  scan.initial.snapshot?.inode == snapshot.inode,
                  snapshot.length >= scan.cursor.offset else { throw Failure.invalidPath }
        } catch {
            recordRegistrationFailure("raw_registration_failed")
            throw error
        }
    }

    /// Freeze explicit selection intent before the source atomically commits
    /// index.json. Recovery requires matching committed rows; a crash before
    /// that commit cannot turn the intent into a delivery acknowledgement.
    func registerSelectedCommit(meetingID: String, indexData: Data) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            guard Self.validComponent(meetingID), indexData.count <= manifest.maxControlBytes else { throw Failure.invalidPath }
            let rows = try JSONDecoder().decode([MeetingAudioArchive.Chunk].self, from: indexData)
            guard !rows.isEmpty, Set(rows.map(\.id)).count == rows.count else { throw Failure.invalidPath }
            let registrations = try control.selectedRegistrations().filter { $0.meetingID == meetingID }
            var firstFailure: Error?
            for row in rows {
                let existing = registrations.first { $0.assets.contains { $0.row == row } }
                let baseline = manifest.committedOriginals.first {
                    $0.meetingID == meetingID && $0.chunkID == row.id && $0.sourceChunk.source == row.source &&
                    $0.sourceChunk.startedAt == row.startedAt && $0.sourceChunk.endedAt == row.endedAt
                }
                var knownOriginal = existing?.assets.first { $0.row == row }?.original
                do {
                    guard Self.validComponent(row.id), Self.validComponent(row.fileName) else {
                        throw AudioHubOriginalReader.Error.unsafePath
                    }
                    if knownOriginal == nil, let baseline {
                        knownOriginal = try AudioHubOutbox.OriginalReference(
                            sourceRelativePath: "meetings/\(meetingID)/audio/\(row.fileName)",
                            sha256: baseline.sha256, byteLength: baseline.byteLength)
                    }
                    if let knownOriginal, existing != nil || baseline != nil {
                        _ = try AudioHubOriginalReader(root: meetingsRoot, reference: knownOriginal)
                        // Keep the first index bytes even after reorder/unrelated additions.
                        continue
                    }
                    let reference = try AudioHubOriginalReader.inspect(root: meetingsRoot,
                        relativePath: "meetings/\(meetingID)/audio/\(row.fileName)")
                    let asset = AudioHubSelectedMeetingAdmission.ManifestAsset(row: row, original: reference)
                    try control.registerSelected(.init(meetingID: meetingID, indexData: indexData, assets: [asset]))
                } catch {
                    let reason: String
                    switch error as? AudioHubOriginalReader.Error {
                    case .missingOriginal: reason = "source_original_missing"
                    case .contentMismatch, .sourceChanged: reason = "source_original_changed"
                    case .unsafePath: reason = "source_original_unsafe"
                    case .readFailed, .invalidRange: reason = "source_original_read_failed"
                    default: reason = "selected_registration_failed"
                    }
                    do {
                        if let existing, reason == "source_original_missing" || reason == "source_original_changed" {
                            try control.recordSelectedGap(registration: existing, reason: reason)
                        } else {
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                            let rowBytes = try encoder.encode(row)
                            try control.recordSelectedRegistrationFailure(.init(meetingID: meetingID,
                                indexSHA256: Self.hash(indexData), rowSHA256: Self.hash(rowBytes),
                                reason: reason, knownOriginal: knownOriginal))
                        }
                    } catch {
                        // Durable observation failure is never admission success.
                        if firstFailure == nil { firstFailure = error }
                    }
                    if firstFailure == nil { firstFailure = error }
                }
            }
            if let firstFailure { throw firstFailure }
        } catch {
            recordRegistrationFailure("selected_registration_failed")
            throw error
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func recordRegistrationFailure(_ value: String) {
        schedulingLock.lock(); registrationFailure = value; schedulingLock.unlock()
    }

    /// Admit exactly one complete raw line for a manifest-listed session.
    @discardableResult
    func scanOnce(sessionID: String) throws -> AudioHubTranscriptScanner.Outcome {
        lock.lock(); defer { lock.unlock() }
        guard let scanner = scanners[sessionID] else { throw Failure.unconfigured }
        return try scanner.step()
    }

    func pendingCount() throws -> Int { try outbox.pending(limit: Int.max).count }

    func registrationFailures() throws -> [AudioHubControlStore.SelectedRegistrationFailure] {
        try control.selectedRegistrationFailures()
    }

    func registrationGapReasons() throws -> [String: String] { try control.selectedGapReasons() }

    func pendingRecords() throws -> [AudioHubOutbox.PendingRecord] {
        try outbox.pending(limit: Int.max)
    }

    func deliverNext(metadataSender: @escaping AudioHubTranscriptDelivery.Sender) async throws -> AudioHubOutbox.PendingRecord? {
        try await withDeliverySlot {
            try await AudioHubTranscriptDelivery(outbox: self.outbox, send: metadataSender).deliverOne()
        }
    }

    func deliverNext(originalTransport: AudioHubOriginalTransport, originalsRoot: URL) async throws -> Bool {
        try await withDeliverySlot {
            try await originalTransport.deliverOne(outbox: self.outbox, control: self.control, originalsRoot: originalsRoot)
        }
    }

    /// Bounded work units; a full batch requests another pass, never silently
    /// abandons the rest of a multi-segment append. Unlisted sources are ignored.
    @discardableResult
    func scanAvailable(limitPerSession: Int = 64) throws -> Bool {
        guard limitPerSession > 0 else { throw Failure.malformedManifest }
        lock.lock(); let ids = Array(scanners.keys).sorted(); lock.unlock()
        var more = false
        var firstError: Error?
        for id in ids {
            do {
                for index in 0..<limitPerSession {
                    guard case .admitted = try scanOnce(sessionID: id) else { break }
                    if index == limitPerSession - 1 { more = true }
                }
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
        return more
    }

    @discardableResult
    func drain(metadataSender: @escaping AudioHubTranscriptDelivery.Sender,
               originalTransport: AudioHubOriginalTransport? = nil,
               limit: Int = 64) async throws -> Bool {
        guard limit > 0 else { throw Failure.malformedManifest }
        for _ in 0..<limit {
            try Task.checkCancellation()
            guard let record = try outbox.pending(limit: 1).first else { return false }
            if record.original == nil {
                _ = try await deliverNext(metadataSender: metadataSender)
            } else {
                guard let originalTransport else { throw Failure.unconfigured }
                _ = try await deliverNext(originalTransport: originalTransport, originalsRoot: meetingsRoot)
            }
        }
        return !(try outbox.pending(limit: 1)).isEmpty
    }

    /// One retained worker coalesces callbacks. Network failure backs off on the
    /// same durable record; later recovery does not depend on another capture.
    func wake(originalsRoot: URL) {
        schedulingLock.lock(); defer { schedulingLock.unlock() }
        guard !stopped else { return }
        workerAgain = true
        guard worker == nil else { return }
        worker = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }; await self.run()
        }
    }

    private func run() async {
        while !Task.isCancelled {
            schedulingLock.lock(); workerAgain = false; schedulingLock.unlock()
            var failed = false
            var more = false
            do { try recover() }
            catch { failed = true; recordFailure("source_admission_failed") }
            do { more = try scanAvailable() }
            catch { failed = true; recordFailure("source_scan_failed") }
            do {
                guard let provision = try provisionLoader() else { throw Failure.unconfigured }
                let metadata = AudioHubMetadataTransport(provision: provision)
                let queued = try await drain(metadataSender: { try await metadata.send($0) },
                    originalTransport: AudioHubOriginalTransport(provision: provision))
                more = more || queued
            } catch is CancellationError { break }
            catch { failed = true; recordFailure("delivery_unavailable") }
            if finishIfIdle(more: more || failed) { return }
            do { try await Task.sleep(nanoseconds: failed ? 30_000_000_000 : 100_000_000) }
            catch { break }
        }
        schedulingLock.lock(); worker = nil; schedulingLock.unlock()
    }

    private func finishIfIdle(more: Bool) -> Bool {
        schedulingLock.lock(); defer { schedulingLock.unlock() }
        if !more && !workerAgain { worker = nil; return true }
        return false
    }

    private func recordFailure(_ value: String?) {
        schedulingLock.lock(); failureCode = value; schedulingLock.unlock()
    }

    func shutdown() {
        schedulingLock.lock(); stopped = true; let task = worker; schedulingLock.unlock()
        task?.cancel()
    }

    /// Sender seam for the owner-controlled transport. Single-flight is
    /// enforced; this method never creates a sender or reads credentials.
    func withDeliverySlot<T>(_ operation: () async throws -> T) async throws -> T {
        schedulingLock.lock()
        guard !deliveryInFlight else { schedulingLock.unlock(); throw Failure.busy }
        deliveryInFlight = true
        schedulingLock.unlock()
        defer { schedulingLock.lock(); deliveryInFlight = false; schedulingLock.unlock() }
        return try await operation()
    }

    /// Walk with directory descriptors, not a racy lstat/path-open pair.
    private static func readIndex(_ relativePath: String, under root: URL, maxBytes: Int) throws -> Data {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "meetings", parts[2] == "audio", parts[3] == "index.json",
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.invalidPath }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { throw Failure.invalidPath }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid() else { throw Failure.invalidPath }
        for component in parts.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard next >= 0 else { throw Failure.invalidPath }
            close(directory); directory = next
            guard fstat(directory, &info) == 0, info.st_uid == getuid() else { throw Failure.invalidPath }
        }
        let fd = openat(directory, "index.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.invalidPath }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= off_t(maxBytes) else { throw Failure.invalidPath }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        var after = stat()
        guard count == data.count, fstat(fd, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw Failure.invalidPath }
        return data
    }
}
