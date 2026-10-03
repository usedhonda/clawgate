import Foundation
import Darwin

/// Owner-supplied activation boundary for the native audio producer.
/// This is deliberately private configuration: an absent file means the route
/// is unconfigured, never "start at EOF" or "scan all sessions".
struct AudioHubActivationManifest: Codable, Equatable {
    struct Session: Codable, Equatable {
        let sessionID: String
        let initial: AudioHubRawTranscriptReader.Checkpoint
    }

    struct SelectedMeeting: Codable, Equatable {
        let meetingID: String
        let indexRelativePath: String
        let assets: [AudioHubSelectedMeetingAdmission.ManifestAsset]
    }

    let version: Int
    let maxMetadataBytes: Int
    let maxControlBytes: Int
    let sessions: [Session]
    let selectedMeetings: [SelectedMeeting]

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
    var lastFailure: String? { schedulingLock.lock(); defer { schedulingLock.unlock() }; return failureCode }

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
        guard manifest.version == 1,
              manifest.maxMetadataBytes == AudioHubActivationManifest.approvedMetadataBytes,
              manifest.maxControlBytes == AudioHubActivationManifest.approvedControlBytes,
              !manifest.sessions.isEmpty || !manifest.selectedMeetings.isEmpty else { return false }
        guard Set(manifest.sessions.map(\.sessionID)).count == manifest.sessions.count,
              manifest.sessions.allSatisfy({ validSession($0) }) else { return false }
        guard Set(manifest.selectedMeetings.map(\.meetingID)).count == manifest.selectedMeetings.count,
              manifest.selectedMeetings.allSatisfy({ validMeeting($0) }) else { return false }
        return true
    }

    private static func validSession(_ item: AudioHubActivationManifest.Session) -> Bool {
        let c = item.initial
        guard !item.sessionID.isEmpty, item.sessionID != ".", item.sessionID != "..",
              !item.sessionID.contains("/"), c.snapshot != nil,
              c.offset <= UInt64(Int64.max), c.physicalLine <= UInt64(Int.max) else { return false }
        return true
    }

    private static func validMeeting(_ item: AudioHubActivationManifest.SelectedMeeting) -> Bool {
        guard !item.meetingID.isEmpty, !item.meetingID.contains("/"),
              item.indexRelativePath == "meetings/\(item.meetingID)/audio/index.json",
              !item.assets.isEmpty else { return false }
        return Set(item.assets.map { $0.row.id }).count == item.assets.count
    }

    /// Recover only the listed scanner checkpoints and selected index rows.
    /// This is admission/recovery, not delivery or activation of networking.
    func recover() throws {
        lock.lock(); defer { lock.unlock() }
        do {
            for entry in manifest.sessions {
                if scanners[entry.sessionID] != nil { continue }
                scanners[entry.sessionID] = try AudioHubTranscriptScanner(
                    sessionsRoot: sessionsRoot, sessionID: entry.sessionID,
                    initialCheckpoint: entry.initial, control: control, outbox: outbox,
                    maxReadBytes: 1 * 1024 * 1024, maxLineBytes: 512 * 1024)
            }
            for meeting in manifest.selectedMeetings {
                let indexData = try Self.readIndex(meeting.indexRelativePath, under: meetingsRoot,
                                                   maxBytes: manifest.maxControlBytes)
                guard !indexData.isEmpty else { throw Failure.invalidPath }
                _ = try AudioHubSelectedMeetingAdmission.admit(
                    meetingID: meeting.meetingID, indexData: indexData,
                    assets: meeting.assets.map(\.asset),
                    selectedIDs: Set(meeting.assets.map { $0.row.id }),
                    originalsRoot: meetingsRoot, outbox: outbox, control: control)
            }
            recordFailure(nil)
        } catch {
            recordFailure("source_admission_failed")
            throw error
        }
    }

    /// Admit exactly one complete raw line for a manifest-listed session.
    @discardableResult
    func scanOnce(sessionID: String) throws -> AudioHubTranscriptScanner.Outcome {
        lock.lock(); defer { lock.unlock() }
        guard let scanner = scanners[sessionID] else { throw Failure.unconfigured }
        return try scanner.step()
    }

    func pendingCount() throws -> Int { try outbox.pending(limit: Int.max).count }

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
