import Foundation
import AVFoundation
import AudioToolbox

/// Captures microphone audio into rolling 16 kHz mono WAV chunks suitable for
/// whisper.cpp. Capture is independently controllable (start/pause/resume/stop)
/// so the user can stop recording at any moment from the menu bar — a hard
/// privacy requirement of the Ambient Context Stream design.
///
/// On-disk chunks are 16-bit PCM mono 16 kHz (what whisper.cpp wants). Note that
/// `AVAudioFile.write(from:)` requires buffers in the file's *processingFormat*
/// (Float32), not the on-disk Int16 format — so capture converts the mic input
/// to a Float32 16 kHz mono record format and lets AVAudioFile encode Int16 to
/// disk.
final class AmbientCaptureManager {
    enum CaptureState: String { case idle, capturing, paused }

    struct CompletedChunk {
        let url: URL
        let sequence: Int
        let rms: Float
        /// Wall-clock chunk start for transcript attribution.
        let startedAt: Date?
        /// Actual number of overlap frames written to this chunk.
        let actualPrimedFrames: AVAudioFrameCount
        /// Rate of the on-disk file (16_000).
        let sampleRate: Double
        /// Whether overlap was proven by a successful overlap write.
        let provenOverlap: Bool
        /// Which audio stream this chunk came from: the microphone (the owner,
        /// plus whoever is in the room) or Chrome's output during a Meet call
        /// (the remote party only).
        var source: Source = .mic

        enum Source: String { case mic, system }
    }

    struct ChunkTimingState {
        var firstLiveSampleAt: Date?
        var actualPrimedFrames: AVAudioFrameCount = 0
        var provenOverlap: Bool = false
        let sequence: Int

        init(sequence: Int) {
            self.sequence = sequence
        }

        mutating func markFirstLiveSample(at date: Date?) {
            guard firstLiveSampleAt == nil, let date else { return }
            firstLiveSampleAt = date
        }

        mutating func markPrimeResult(_ actualPrimedFrames: AVAudioFrameCount) {
            self.actualPrimedFrames = actualPrimedFrames
            provenOverlap = actualPrimedFrames > 0
        }

        mutating func reset(for sequence: Int) {
            self = Self.init(sequence: sequence)
        }

        func startedAt(sampleRate: Double) -> Date? {
            guard let firstLiveSampleAt else { return nil }
            return AmbientCaptureManager.startedAt(
                firstLiveSampleAt: firstLiveSampleAt,
                actualPrimedFrames: actualPrimedFrames,
                sampleRate: sampleRate,
                provenOverlap: provenOverlap && sampleRate.isFinite && sampleRate > 0
            )
        }

        func completedChunk(url: URL, sampleRate: Double, rms: Float = 0) -> CompletedChunk {
            return CompletedChunk(
                url: url,
                sequence: sequence,
                rms: rms,
                startedAt: startedAt(sampleRate: sampleRate),
                actualPrimedFrames: actualPrimedFrames,
                sampleRate: sampleRate,
                provenOverlap: provenOverlap && sampleRate.isFinite && sampleRate > 0
            )
        }
    }

    /// Test seam for AVAudioTime -> Date conversion. Production uses host
    /// clock math; tests can inject a deterministic mapping.
    private static func hostTapTimeToDate(_ tapTime: AVAudioTime) -> Date? {
        guard tapTime.isHostTimeValid else { return nil }
        let nowNanos = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        let sampleNanos = AudioConvertHostTimeToNanos(tapTime.hostTime)
        let nowWall = Date().timeIntervalSince1970
        let nowHost = TimeInterval(nowNanos) / 1_000_000_000.0
        let sampleWall = TimeInterval(sampleNanos) / 1_000_000_000.0
        return Date(timeIntervalSince1970: nowWall - (nowHost - sampleWall))
    }

    static func startedAt(
        firstLiveSampleAt: Date,
        actualPrimedFrames: AVAudioFrameCount,
        sampleRate: Double,
        provenOverlap: Bool
    ) -> Date? {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        guard provenOverlap, actualPrimedFrames > 0 else { return firstLiveSampleAt }
        return firstLiveSampleAt - TimeInterval(actualPrimedFrames) / sampleRate
    }

    /// The microphone session lives in the backend, on its own queue, and is
    /// addressed by generation: every start retires the previous generation, so
    /// a completion or a buffer that arrives late for an old one is dropped.
    private let backend: AmbientCaptureBackend
    private var backendGeneration = 0
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    /// Buffer format handed to AVAudioFile.write — must match AVAudioFile.processingFormat.
    private let recordFormat: AVAudioFormat
    /// On-disk encoding (16-bit PCM mono 16 kHz) for whisper.cpp.
    private let fileSettings: [String: Any]
    private let chunkFrameLimit: AVAudioFrameCount
    /// Carry the last N samples into the next chunk so a sentence split across
    /// the boundary keeps context (matches the 3s overlap in the STT preset).
    private let overlapFrames: Int
    /// Rolling-buffer retention; chunks older than this are pruned on rotation.
    private let retentionSeconds: TimeInterval

    private var currentFile: AVAudioFile?
    private var currentChunkURL: URL?
    private var framesInCurrentChunk: AVAudioFrameCount = 0
    /// Sum of squared samples for the current chunk, accumulated as we write.
    /// RMS is measured here (not by re-reading the file on finalize) because a
    /// read immediately after the writer is released can race the header flush
    /// and fail — which silently disabled the silence gate (fail-open).
    private var sumSquaresInCurrentChunk: Double = 0
    private var currentChunkTiming: ChunkTimingState
    private var chunkSeq = 0
    private var overlapTail: [Float] = []

    private let lock = NSLock()
    private(set) var state: CaptureState = .idle

    /// Liveness signals. The audio tap thread writes these; the status/monitor
    /// threads read them. A separate lock keeps tap recording off the main
    /// capture lock's hot path. `lastTapAt` is the earliest, finest wedge signal
    /// (the tap fires ~10×/s even in a silent room, so it going stale means the
    /// engine stopped delivering buffers — i.e. wedged).
    private let livenessLock = NSLock()
    private var _lastTapAt: Date?
    private var _lastChunkReadyAt: Date?
    private var _chunksSurfaced = 0
    private var _recoveryCount = 0
    private var _lastRecoveryAt: Date?
    private var _lastRecoveryReason: String?
    /// Automatic recoveries refused because one ran recently. Counted, not
    /// acted on: every automatic recovery rebuilds the engine, and a rebuilt
    /// engine binds to the system default input before it is moved -- with a
    /// Bluetooth headset that touch alone is enough to drop it into hands-free
    /// mode. Five such rebuilds in a few minutes were observed on 2026-09-02.
    private var _suppressedAutoRecovers = 0
    private var _lastSuppressedRecoveryReason: String?
    /// What the user asked for and what the engine is actually on. Kept apart
    /// because they have been observed to differ: the engine can be moved off
    /// the requested device after start, silently, and only a read-back shows it.
    private var _requestedInputDeviceUID: String?
    private var _actualInputDeviceUID: String?
    private var _actualInputDeviceName: String?
    private var _actualInputObservedAt: Date?
    private var _backendPhase: BackendPhase = .idle
    private var _backendPhaseSince: Date = Date()
    private var preferredDeviceUID: String?
    private let deadlineQueue = DispatchQueue(label: "ai.clawgate.ambient.backend-deadline", qos: .utility)
    private let resolveAudioDeviceID: (String) -> AudioDeviceID?
    private let tapTimeToDate: (AVAudioTime) -> Date?
    private let writeAudioFile: (AVAudioFile, AVAudioPCMBuffer) throws -> AVAudioFrameCount

    /// Snapshot of capture liveness for /v1/ambient/status, the doctor check,
    /// and the in-app health monitor.
    struct Liveness {
        var lastTapAt: Date?
        var lastChunkReadyAt: Date?
        var chunksSurfaced: Int
        var recoveryCount: Int
        var lastRecoveryAt: Date?
        var lastRecoveryReason: String?
        var requestedInputDeviceUID: String?
        var actualInputDeviceUID: String?
        var actualInputDeviceName: String?
        /// When the actual device was last confirmed by the backend. Status
        /// shows it so an old observation is never mistaken for a current one.
        var actualInputObservedAt: Date?
        /// True only when a device was requested and the backend opened another.
        var inputDeviceDrifted: Bool
        var suppressedAutoRecovers: Int
        var lastSuppressedRecoveryReason: String?
        var backendPhase: BackendPhase
        var backendPhaseSince: Date
        var backendGeneration: Int
    }

    /// Where the backend is in its lifecycle, as last reported. `timedOut`
    /// is terminal for this process: a session that did not finish starting
    /// or stopping cannot be cancelled, so no second session is started beside
    /// it. The process watchdog reads this and restarts the app.
    enum BackendPhase: String {
        case idle, starting, running, stopping, failed, timedOut
    }

    func livenessSnapshot() -> Liveness {
        livenessLock.lock(); defer { livenessLock.unlock() }
        let drifted = Self.classifyDeviceApplication(
            requestedUID: _requestedInputDeviceUID,
            actualUID: _actualInputDeviceUID
        ) == .drifted
        return Liveness(lastTapAt: _lastTapAt,
                        lastChunkReadyAt: _lastChunkReadyAt,
                        chunksSurfaced: _chunksSurfaced,
                        recoveryCount: _recoveryCount,
                        lastRecoveryAt: _lastRecoveryAt,
                        lastRecoveryReason: _lastRecoveryReason,
                        requestedInputDeviceUID: _requestedInputDeviceUID,
                        actualInputDeviceUID: _actualInputDeviceUID,
                        actualInputDeviceName: _actualInputDeviceName,
                        actualInputObservedAt: _actualInputObservedAt,
                        inputDeviceDrifted: drifted,
                        suppressedAutoRecovers: _suppressedAutoRecovers,
                        lastSuppressedRecoveryReason: _lastSuppressedRecoveryReason,
                        backendPhase: _backendPhase,
                        backendPhaseSince: _backendPhaseSince,
                        backendGeneration: backendGeneration)
    }

    // MARK: - Automatic recovery admission

    /// At most one automatic recovery per window. Manual recovery (the
    /// /capture/recover endpoint, a microphone selection) is never gated;
    /// only the engine's own reactions are, because those are the ones that
    /// can chain: a rebuild touches the default input, the headset reconfigures,
    /// the engine posts a change, and the change asks for another rebuild.
    static let autoRecoverCooldown: TimeInterval = 120

    /// Pure admission rule, shared by every automatic path so they form one
    /// budget rather than one each. The first recovery is always admitted.
    static func shouldAdmitAutoRecover(lastRecoveryAt: Date?, now: Date) -> Bool {
        guard let lastRecoveryAt else { return true }
        return now.timeIntervalSince(lastRecoveryAt) > autoRecoverCooldown
    }

    /// Recover if the budget allows; otherwise record the refusal and return
    /// false. Callers log; they must not retry on their own clock.
    @discardableResult
    func autoRecover(reason: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .capturing else { return false }
        guard backendPhaseLocked() != .timedOut else {
            log("ambient capture auto-recover refused (backend timed out; process restart required): \(reason)")
            return false
        }
        livenessLock.lock()
        let admitted = Self.shouldAdmitAutoRecover(lastRecoveryAt: _lastRecoveryAt, now: Date())
        if !admitted {
            _suppressedAutoRecovers += 1
            _lastSuppressedRecoveryReason = reason
        }
        livenessLock.unlock()
        guard admitted else {
            log("ambient capture auto-recover refused (cooldown): \(reason)")
            return false
        }
        hardRecoverLocked(reason: reason)
        return true
    }

    /// Whether the engine honoured the requested input device.
    ///
    /// `notRequested` is the fail-soft case that already existed: the user chose
    /// nothing, or chose a device that is not present, and the system default is
    /// used on purpose. `drifted` is different and must not be folded into it:
    /// the device exists, was asked for, and the engine is on something else.
    enum DeviceApplication: Equatable {
        case notRequested
        case matched
        case drifted
    }

    static func classifyDeviceApplication(requestedUID: String?, actualUID: String?) -> DeviceApplication {
        guard let requestedUID, !requestedUID.isEmpty else { return .notRequested }
        guard let actualUID else { return .drifted }
        return actualUID == requestedUID ? .matched : .drifted
    }

    /// Whether the backend opened a device other than the one requested,
    /// from the last start report. Cached on purpose: the device an
    /// AVCaptureDeviceInput holds cannot change underneath it, and asking
    /// Core Audio from a status call is how the previous design hung.
    func refreshInputDeviceObservation() -> Bool {
        livenessLock.lock(); defer { livenessLock.unlock() }
        return Self.classifyDeviceApplication(
            requestedUID: _requestedInputDeviceUID,
            actualUID: _actualInputDeviceUID
        ) == .drifted
    }

    /// Classify capture liveness from the tap-staleness. Shared by status, the
    /// doctor check, and the health monitor so all three agree. Pure + testable.
    /// `capturing` must be true (state == .capturing); otherwise liveness is N/A.
    static func classifyLiveness(capturing: Bool, secondsSinceLastTap: Int) -> String {
        guard capturing else { return "unknown" }
        if secondsSinceLastTap < 0 { return "unknown" }   // capturing but no tap recorded yet (just started)
        if secondsSinceLastTap <= livenessStaleSeconds { return "live" }
        if secondsSinceLastTap <= livenessWedgedSeconds { return "stale" }
        return "wedged"
    }
    /// A healthy tap fires ~10×/s, so >15s without one is suspicious and >30s
    /// while still "capturing" means the engine has stopped (wedged).
    static let livenessStaleSeconds = 15
    static let livenessWedgedSeconds = 30

    private func recordTap() {
        livenessLock.lock(); _lastTapAt = Date(); livenessLock.unlock()
    }

    private func recordChunkReady() {
        livenessLock.lock(); _lastChunkReadyAt = Date(); _chunksSurfaced += 1; livenessLock.unlock()
    }

    let chunkSeconds: Int
    /// Called (off the audio thread) when a chunk file is finalized and ready.
    /// Arguments: completed metadata for transcript attribution + silence gate.
    var onChunkReady: ((CompletedChunk) -> Void)?
    private let log: (String) -> Void

    /// Cuts chunks inside speech pauses instead of on the fixed grid. Off by
    /// default so the fixed-grid timing tests keep their meaning; the controller
    /// turns it on for live capture.
    private var utteranceChunker: UtteranceChunker?

    init(chunkSeconds: Int = 30,
         overlapSeconds: Int = 3,
         utteranceChunking: Bool = false,
         retentionSeconds: TimeInterval = 6 * 3600,
         resolveAudioDeviceID: @escaping (String) -> AudioDeviceID? = MicrophoneDeviceService.resolveAudioDeviceID,
         tapTimeToDate: @escaping (AVAudioTime) -> Date? = AmbientCaptureManager.hostTapTimeToDate,
         writeAudioFile: @escaping (AVAudioFile, AVAudioPCMBuffer) throws -> AVAudioFrameCount = { file, buffer in
            try file.write(from: buffer)
            return buffer.frameLength
         },
         log: @escaping (String) -> Void = { _ in }) {
        self.chunkSeconds = max(5, chunkSeconds)
        self.utteranceChunker = utteranceChunking
            ? UtteranceChunker(maxSeconds: Double(max(5, chunkSeconds)), forcedOverlapSeconds: 1)
            : nil
        self.overlapFrames = max(0, overlapSeconds) * 16_000
        self.retentionSeconds = retentionSeconds
        self.resolveAudioDeviceID = resolveAudioDeviceID
        self.tapTimeToDate = tapTimeToDate
        self.writeAudioFile = writeAudioFile
        self.log = log
        self.recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        self.fileSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.chunkFrameLimit = AVAudioFrameCount(self.chunkSeconds * 16_000)
        self.currentChunkTiming = ChunkTimingState(sequence: 0)
        self.backend = AmbientCaptureBackend(log: log)
        self.backend.onBuffer = { [weak self] generation, buffer, format, time in
            self?.handleBuffer(generation: generation, buffer: buffer, format: format, at: time)
        }
        self.backend.onEvent = { [weak self] generation, event in
            self?.handleBackendEvent(generation: generation, event: event)
        }
    }

    /// Set by the owner. Called (off the capture lock) when the backend times
    /// out, with a typed reason to persist: the owner keeps the user's intent
    /// to stream separate from this safety inhibit and must not resume the
    /// microphone on the next launch until a person clears it.
    var onQuarantine: ((String) -> Void)?

    /// Set by the owner. Called once per generation, off the capture lock,
    /// when the first buffer from a freshly started session is accepted. That
    /// -- not the start being accepted, not the session reporting running --
    /// is the moment a start has demonstrably succeeded, and the only moment
    /// the owner may clear the auto-resume inhibit.
    var onFirstBuffer: ((Int) -> Void)?
    private var firstBufferSeenForGeneration = 0

    // MARK: - Permission

    static func micAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Lifecycle

    /// Begin capturing. Returns once the request is handed to the backend;
    /// the session opens asynchronously and `livenessSnapshot().backendPhase`
    /// reports `running` when it has. Throws only for a failure that is known
    /// immediately (the chunk file could not be opened).
    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .idle else { return }
        try beginBackendLocked()
        state = .capturing
        log("ambient capture start requested (chunk=\(chunkSeconds)s, 16kHz mono)")
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard state == .capturing else { return }
        teardownBackendLocked(finalize: true)
        state = .paused
        log("ambient capture paused")
    }

    func resume() throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .paused else { return }
        try beginBackendLocked()
        state = .capturing
        log("ambient capture resume requested")
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard state != .idle else { return }
        teardownBackendLocked(finalize: true)
        state = .idle
        log("ambient capture stopped")
    }

    /// Hard-recover a wedged capture in-process: retire the current session and
    /// ask the backend for a fresh one. Keeps `state` == .capturing and the same
    /// session/chunk sequence so continuity and the ingest window are preserved.
    /// This is the self-heal action; if the fresh session also fails to start,
    /// state stays .capturing so the monitor/watchdog escalates (e.g. to a
    /// process restart). Refused outright once the backend has timed out.
    func hardRecover(reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard state == .capturing else { return }
        hardRecoverLocked(reason: reason)
    }

    private func hardRecoverLocked(reason: String) {
        if backendPhaseLocked() == .timedOut {
            // A session that never finished cannot be cancelled. Starting
            // another beside it is how a process ends up holding a headset's
            // input from a thread that never returns; the watchdog restarts
            // the process instead.
            log("ambient capture hardRecover refused: backend timed out; process restart required (\(reason))")
            return
        }
        log("ambient capture hardRecover: \(reason)")
        teardownBackendLocked(finalize: true)
        do {
            try beginBackendLocked()
            recordRecovery(reason: reason)
            log("ambient capture hardRecover requested")
        } catch {
            recordRecovery(reason: "\(reason) (FAILED: \(error.localizedDescription))")
            log("ambient capture hardRecover FAILED: \(error)")
        }
    }

    func setPreferredDevice(uid: String?) {
        lock.lock(); defer { lock.unlock() }
        preferredDeviceUID = uid
        guard state == .capturing else { return }
        log("ambient capture mic device changed")
        teardownBackendLocked(finalize: true)
        do {
            try beginBackendLocked()
            recordRecovery(reason: "device changed")
            log("ambient capture mic device apply requested")
        } catch {
            recordRecovery(reason: "device changed (FAILED: \(error.localizedDescription))")
            log("ambient capture mic device apply FAILED: \(error)")
        }
    }

    /// TEST ONLY: simulate the wedge by tearing down the engine/tap WITHOUT
    /// changing `state`, exactly reproducing the observed failure (taps stop,
    /// captureState still reports "capturing"). Lets the detect→recover loop be
    /// verified on demand instead of waiting for a rare spontaneous engine death.
    func simulateWedge() {
        lock.lock(); defer { lock.unlock() }
        guard state == .capturing else { return }
        teardownBackendLocked(finalize: false)
        log("ambient capture WEDGE SIMULATED (backend torn down, state left .capturing)")
    }

    private func recordRecovery(reason: String) {
        livenessLock.lock()
        _recoveryCount += 1
        _lastRecoveryAt = Date()
        _lastRecoveryReason = reason
        _lastTapAt = Date()   // give the fresh engine the staleness window before re-flagging
        livenessLock.unlock()
    }

    // MARK: - Backend (lock held)

    /// How long a start may take before this process gives up on it. Long
    /// enough for a slow device to come up; short enough that a user notices
    /// the status change rather than a silent gap.
    static let backendStartDeadline: TimeInterval = 20

    private func backendPhaseLocked() -> BackendPhase {
        livenessLock.lock(); defer { livenessLock.unlock() }
        return _backendPhase
    }

    private func setBackendPhase(_ phase: BackendPhase) {
        livenessLock.lock()
        _backendPhase = phase
        _backendPhaseSince = Date()
        livenessLock.unlock()
    }

    /// Open the chunk file now and ask the backend for a session. Nothing here
    /// waits on Core Audio. The generation minted here is the only one whose
    /// completion, buffers, or events will be accepted.
    private func beginBackendLocked() throws {
        backendGeneration += 1
        let generation = backendGeneration
        converter = nil
        converterInputFormat = nil
        try openNewChunkLocked()

        let requested = preferredDeviceUID.flatMap { $0.isEmpty ? nil : $0 }
        livenessLock.lock()
        _requestedInputDeviceUID = requested
        _actualInputDeviceUID = nil
        _actualInputDeviceName = nil
        _actualInputObservedAt = nil
        livenessLock.unlock()
        setBackendPhase(.starting)

        backend.start(deviceUID: requested, generation: generation) { [weak self] result in
            self?.handleStartResult(generation: generation, requested: requested, result: result)
        }
        deadlineQueue.asyncAfter(deadline: .now() + Self.backendStartDeadline) { [weak self] in
            self?.handleStartDeadline(generation: generation)
        }
    }

    /// The one failure that is handled by falling back rather than failing:
    /// the selected microphone is not present. That has always meant "use the
    /// system default", and it is never reported as drift, because nothing was
    /// opened that the user did not choose. Pure, so the contract is testable.
    static func shouldFallBackToDefault(afterStartFailure error: Error, requestedUID: String?) -> Bool {
        guard let requestedUID, !requestedUID.isEmpty else { return false }
        if case AmbientCaptureBackend.BackendError.deviceNotFound = error { return true }
        return false
    }

    private func handleStartResult(generation: Int, requested: String?, result: Result<AmbientCaptureBackend.StartedInfo, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard generation == backendGeneration else {
            log("ambient capture ignoring start result for retired generation \(generation)")
            return
        }
        guard backendPhaseLocked() == .starting else { return }
        switch result {
        case .success(let info):
            livenessLock.lock()
            _actualInputDeviceUID = info.deviceUID
            _actualInputDeviceName = info.deviceName
            _actualInputObservedAt = Date()
            _lastTapAt = Date()   // fresh session gets the staleness window before liveness judges it
            livenessLock.unlock()
            setBackendPhase(.running)
            log("ambient capture running on \(info.deviceName) [\(info.deviceUID)] \(Int(info.sampleRate))Hz ch=\(info.channels)")
        case .failure(let error):
            // The selected microphone is not present: fall back to the system
            // default, once, exactly as before. That is a fail-soft path and is
            // never reported as drift. Any other failure is a failed start.
            if Self.shouldFallBackToDefault(afterStartFailure: error, requestedUID: requested) {
                log("ambient capture selected mic not found; using system default")
                livenessLock.lock(); _requestedInputDeviceUID = nil; livenessLock.unlock()
                let retryGeneration = backendGeneration
                backend.start(deviceUID: nil, generation: retryGeneration) { [weak self] retry in
                    self?.handleStartResult(generation: retryGeneration, requested: nil, result: retry)
                }
                return
            }
            setBackendPhase(.failed)
            recordRecovery(reason: "start failed: \(error)")
            log("ambient capture start FAILED: \(error)")
        }
    }

    private func handleStartDeadline(generation: Int) {
        lock.lock()
        guard generation == backendGeneration, backendPhaseLocked() == .starting else { lock.unlock(); return }
        setBackendPhase(.timedOut)
        let quarantine = onQuarantine
        lock.unlock()
        log("ambient capture backend did not start within \(Int(Self.backendStartDeadline))s; timed out, no further session in this process")
        quarantine?("backend_timeout")
    }

    private func handleBackendEvent(generation: Int, event: AmbientCaptureBackend.Event) {
        lock.lock()
        guard generation == backendGeneration, state == .capturing else { lock.unlock(); return }
        lock.unlock()
        switch event {
        case .runtimeError(let message):
            log("ambient capture session runtime error: \(message)")
            autoRecover(reason: "session runtime error: \(message)")
        case .interrupted:
            log("ambient capture session interrupted")
        case .interruptionEnded:
            log("ambient capture session interruption ended")
            autoRecover(reason: "session interruption ended")
        }
    }

    /// Retire the current generation and release the session. The stop itself
    /// runs on the backend queue and is not awaited: anything still in flight
    /// for the old generation is dropped by the generation check, and the next
    /// start queues behind the stop on the backend's own serial queue.
    private func teardownBackendLocked(finalize: Bool) {
        backendGeneration += 1
        setBackendPhase(.stopping)
        let generation = backendGeneration
        backend.stop { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if generation == self.backendGeneration, self.backendPhaseLocked() == .stopping {
                self.setBackendPhase(.idle)
            }
            self.lock.unlock()
        }
        livenessLock.lock()
        _requestedInputDeviceUID = nil
        _actualInputDeviceUID = nil
        _actualInputDeviceName = nil
        _actualInputObservedAt = nil
        livenessLock.unlock()
        if finalize { finalizeChunkLocked() }
        converter = nil
        converterInputFormat = nil
        overlapTail.removeAll()
        if utteranceChunker != nil {
            utteranceChunker = UtteranceChunker(maxSeconds: Double(chunkSeconds), forcedOverlapSeconds: 1)
        }
    }

    // MARK: - Chunk files (lock held except onChunkReady dispatch)

    private func openNewChunkLocked() throws {
        chunkSeq += 1
        let url = defaultChunkURLLocked()
        currentFile = try AVAudioFile(forWriting: url, settings: fileSettings)
        currentChunkURL = url
        framesInCurrentChunk = 0
        sumSquaresInCurrentChunk = 0
        currentChunkTiming.reset(for: chunkSeq)
    }

    private func openNewChunkLocked(at url: URL) throws {
        currentFile = try AVAudioFile(forWriting: url, settings: fileSettings)
        currentChunkURL = url
        framesInCurrentChunk = 0
        sumSquaresInCurrentChunk = 0
        currentChunkTiming.reset(for: chunkSeq)
    }

    private func defaultChunkURLLocked() -> URL {
        let dir = AmbientStorage.rollingDir(for: Date())
        AmbientStorage.ensureDir(dir)
        let name = String(format: "chunk-%06d.wav", chunkSeq)
        return dir.appendingPathComponent(name)
    }

    private func finalizeChunkLocked() -> CompletedChunk? {
        guard let url = currentChunkURL else { return nil }
        let frames = framesInCurrentChunk
        let sumSquares = sumSquaresInCurrentChunk
        currentFile = nil
        currentChunkURL = nil
        framesInCurrentChunk = 0
        sumSquaresInCurrentChunk = 0
        let sampleRate = recordFormat.sampleRate
        let metadata = currentChunkTiming.completedChunk(url: url, sampleRate: sampleRate)
        currentChunkTiming.reset(for: chunkSeq)
        // Only surface chunks with real audio (skip empty stubs).
        guard frames > 16_000 else {  // < ~1s of audio
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let rms = Float((sumSquares / Double(frames)).squareRoot())
        recordChunkReady()   // a real chunk was finalized (incl. silence chunks — silence-safe liveness)
        let cb = onChunkReady
        let retain = retentionSeconds
        DispatchQueue.global(qos: .utility).async {
            cb?(CompletedChunk(
                url: metadata.url,
                sequence: metadata.sequence,
                rms: rms,
                startedAt: metadata.startedAt,
                actualPrimedFrames: metadata.actualPrimedFrames,
                sampleRate: sampleRate,
                provenOverlap: metadata.provenOverlap
            ))
            AmbientStorage.pruneRolling(olderThan: retain)
        }
        return metadata
    }

    // MARK: - Audio thread

    private func firstLiveSampleDate(from tapTime: AVAudioTime?) -> Date? {
        guard let tapTime else { return nil }
        return tapTimeToDate(tapTime)
    }

    private func handleBuffer(generation: Int, buffer: AVAudioPCMBuffer, format: AVAudioFormat, at tapTime: AVAudioTime?) {
        lock.lock()
        guard generation == backendGeneration, state == .capturing else { lock.unlock(); return }
        var firstBuffer: ((Int) -> Void)?
        if firstBufferSeenForGeneration != generation {
            firstBufferSeenForGeneration = generation
            firstBuffer = onFirstBuffer
        }
        if converter == nil || converterInputFormat != format {
            converter = AVAudioConverter(from: format, to: recordFormat)
            converterInputFormat = format
            if converter == nil { log("ambient capture cannot build audio converter from \(format)") }
        }
        let converter = self.converter
        lock.unlock()
        firstBuffer?(generation)

        recordTap()   // the session delivered a buffer: liveness proof, even before conversion
        let firstLiveSampleDate = firstLiveSampleDate(from: tapTime)
        guard let converter else { return }
        let ratio = recordFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var convErr: NSError?
        let status = converter.convert(to: outBuf, error: &convErr) { _, inStatus in
            if consumed { inStatus.pointee = .noDataNow; return nil }
            consumed = true
            inStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, outBuf.frameLength > 0 else {
            if let convErr { log("ambient convert error: \(convErr.localizedDescription)") }
            return
        }

        lock.lock(); defer { lock.unlock() }
        guard currentFile != nil else { return }
        writeBufferLocked(outBuf, firstLiveSampleDate: firstLiveSampleDate)
    }

    // MARK: - Write + overlap (lock held)

    private func writeBufferLocked(_ buf: AVAudioPCMBuffer, firstLiveSampleDate: Date?) {
        guard let file = currentFile else { return }
        do {
            let writtenFrames = try writeAudioFile(file, buf)
            let normalizedWrittenFrames = min(writtenFrames, buf.frameLength)
            guard normalizedWrittenFrames > 0 else { return }
            framesInCurrentChunk += normalizedWrittenFrames
            currentChunkTiming.markFirstLiveSample(at: firstLiveSampleDate)
            accumulateSumSquares(buf, frameLength: normalizedWrittenFrames)
            appendOverlapTail(buf, frameLength: normalizedWrittenFrames)
            // Pause-aligned cuts when enabled; the fixed limit stays as the cap.
            var overlapLimit: Int? = nil
            var rollover = framesInCurrentChunk >= chunkFrameLimit
            if var chunker = utteranceChunker, let ch = buf.floatChannelData {
                let decision = chunker.consume(UnsafeBufferPointer(start: ch[0], count: Int(normalizedWrittenFrames)))
                utteranceChunker = chunker
                if case .cut(let overlap) = decision {
                    rollover = true
                    overlapLimit = overlap
                }
            }
            if rollover {
                _ = finalizeChunkLocked()
                try openNewChunkLocked()
                let primedFrames = primeOverlapLocked(limit: overlapLimit)
                currentChunkTiming.markPrimeResult(primedFrames)
                utteranceChunker?.didStartChunk(primed: Int(primedFrames))
            }
        } catch {
            log("ambient capture write error: \(error)")
        }
    }

    /// Accumulate squared sample energy for the current chunk's RMS.
    private func accumulateSumSquares(_ buf: AVAudioPCMBuffer, frameLength: AVAudioFrameCount? = nil) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(min(buf.frameLength, frameLength ?? buf.frameLength))
        var sum = 0.0
        for i in 0..<n { let v = Double(ch[0][i]); sum += v * v }
        sumSquaresInCurrentChunk += sum
    }

    /// Keep the most recent `overlapFrames` Float samples for the next chunk.
    private func appendOverlapTail(_ buf: AVAudioPCMBuffer, frameLength: AVAudioFrameCount? = nil) {
        guard overlapFrames > 0, let ch = buf.floatChannelData else { return }
        let n = Int(min(buf.frameLength, frameLength ?? buf.frameLength))
        overlapTail.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        if overlapTail.count > overlapFrames {
            overlapTail.removeFirst(overlapTail.count - overlapFrames)
        }
    }

    /// Prepend the retained tail to a freshly opened chunk (3s overlap), or only
    /// its last `limit` samples (a pause cut needs none).
    private func primeOverlapLocked(limit: Int? = nil) -> AVAudioFrameCount {
        if let limit, limit < overlapTail.count {
            overlapTail.removeFirst(overlapTail.count - max(0, limit))
        }
        guard overlapFrames > 0, !overlapTail.isEmpty,
              let file = currentFile,
              let buf = AVAudioPCMBuffer(pcmFormat: recordFormat,
                                         frameCapacity: AVAudioFrameCount(overlapTail.count)),
              let ch = buf.floatChannelData else { return 0 }
        let n = overlapTail.count
        for i in 0..<n { ch[0][i] = overlapTail[i] }
        buf.frameLength = AVAudioFrameCount(n)
        do {
            let writtenFrames = try writeAudioFile(file, buf)
            let normalizedWrittenFrames = min(writtenFrames, buf.frameLength)
            framesInCurrentChunk += normalizedWrittenFrames
            if normalizedWrittenFrames > 0 {
                accumulateSumSquares(buf, frameLength: normalizedWrittenFrames)
                appendOverlapTail(buf, frameLength: normalizedWrittenFrames)
            }
            return normalizedWrittenFrames
        } catch {
            log("ambient overlap prime error: \(error)")
        }
        return 0
    }

#if DEBUG
    func testOpenChunk(at url: URL? = nil) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let url {
            chunkSeq += 1
            try openNewChunkLocked(at: url)
            return url
        }
        try openNewChunkLocked()
        return currentChunkURL!
    }

    func testWriteBuffer(_ buf: AVAudioPCMBuffer, firstLiveSampleDate: Date?) {
        lock.lock()
        defer { lock.unlock() }
        writeBufferLocked(buf, firstLiveSampleDate: firstLiveSampleDate)
    }

    func testPrimeOverlap() -> AVAudioFrameCount {
        lock.lock()
        defer { lock.unlock() }
        return primeOverlapLocked()
    }

    func testCurrentChunkTiming() -> AmbientCaptureManager.ChunkTimingState {
        lock.lock()
        defer { lock.unlock() }
        return currentChunkTiming
    }

    func testCurrentChunkSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return chunkSeq
    }

    func testCurrentChunkURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return currentChunkURL
    }

    func testFinalizeCurrentChunk() -> AmbientCaptureManager.CompletedChunk? {
        lock.lock()
        defer { lock.unlock() }
        return finalizeChunkLocked()
    }

    func testStartedAtFromCurrentTiming(sampleRate: Double) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return currentChunkTiming.startedAt(sampleRate: sampleRate)
    }

    func testFirstLiveSampleDate(from tapTime: AVAudioTime?) -> Date? {
        return firstLiveSampleDate(from: tapTime)
    }

    func testSetOverlapTail(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        overlapTail = samples
    }

    func testMarkCurrentChunkFirstLiveSample(_ date: Date?) {
        lock.lock()
        defer { lock.unlock() }
        currentChunkTiming.markFirstLiveSample(at: date)
    }

    func testMarkPrimeResult(_ result: AVAudioFrameCount) {
        lock.lock()
        defer { lock.unlock() }
        currentChunkTiming.markPrimeResult(result)
    }

    func testPrimeAndMark() -> AVAudioFrameCount {
        lock.lock()
        defer { lock.unlock() }
        let primed = primeOverlapLocked()
        currentChunkTiming.markPrimeResult(primed)
        return primed
    }
#endif
}
