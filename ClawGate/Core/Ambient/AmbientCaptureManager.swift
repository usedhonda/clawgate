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

    /// `var` so a wedge recovery can swap in a fresh AVAudioEngine object — the
    /// only reliable in-process reset when the engine stops delivering buffers.
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
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
    private var preferredDeviceUID: String?
    private var configurationChangeObserver: NSObjectProtocol?
    /// Guarded by `configurationLock`, never by `lock`: the notification can
    /// arrive on any thread, and taking the capture lock from inside it risks
    /// re-entering a section that is mid-restart.
    private var pendingConfigurationRecover: DispatchWorkItem?
    private let configurationLock = NSLock()
    private let configurationQueue = DispatchQueue(label: "ai.clawgate.ambient.engine-config", qos: .utility)
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
        /// True only when a device was requested and the engine is on another.
        var inputDeviceDrifted: Bool
        var suppressedAutoRecovers: Int
        var lastSuppressedRecoveryReason: String?
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
                        inputDeviceDrifted: drifted,
                        suppressedAutoRecovers: _suppressedAutoRecovers,
                        lastSuppressedRecoveryReason: _lastSuppressedRecoveryReason)
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

    /// Re-read which device the live engine is on and record it. Returns true
    /// when it has drifted from the requested device. Cheap, so status and the
    /// health monitor call it on every look rather than trusting the last one.
    func refreshInputDeviceObservation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .capturing else { return false }
        return observeInputDeviceLocked(engine.inputNode)
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

    init(chunkSeconds: Int = 30,
         overlapSeconds: Int = 3,
         retentionSeconds: TimeInterval = 6 * 3600,
         resolveAudioDeviceID: @escaping (String) -> AudioDeviceID? = MicrophoneDeviceService.resolveAudioDeviceID,
         tapTimeToDate: @escaping (AVAudioTime) -> Date? = AmbientCaptureManager.hostTapTimeToDate,
         writeAudioFile: @escaping (AVAudioFile, AVAudioPCMBuffer) throws -> AVAudioFrameCount = { file, buffer in
            try file.write(from: buffer)
            return buffer.frameLength
         },
         log: @escaping (String) -> Void = { _ in }) {
        self.chunkSeconds = max(5, chunkSeconds)
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
    }

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

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .idle else { return }
        try beginEngineLocked()
        state = .capturing
        log("ambient capture started (chunk=\(chunkSeconds)s, 16kHz mono)")
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard state == .capturing else { return }
        teardownEngineLocked(finalize: true)
        state = .paused
        log("ambient capture paused")
    }

    func resume() throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .paused else { return }
        try beginEngineLocked()
        state = .capturing
        log("ambient capture resumed")
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard state != .idle else { return }
        teardownEngineLocked(finalize: true)
        state = .idle
        log("ambient capture stopped")
    }

    /// Hard-recover a wedged capture in-process: tear down the (dead) engine and
    /// tap, swap in a FRESH AVAudioEngine, and re-install the tap. Keeps `state`
    /// == .capturing and the same session/chunk sequence so continuity and the
    /// ingest window are preserved. This is the self-heal action; if the fresh
    /// engine also fails to start, state stays .capturing so the monitor/watchdog
    /// escalates (e.g. to a process restart).
    func hardRecover(reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard state == .capturing else { return }
        hardRecoverLocked(reason: reason)
    }

    private func hardRecoverLocked(reason: String) {
        log("ambient capture hardRecover: \(reason)")
        teardownEngineLocked(finalize: true)
        engine = AVAudioEngine()   // fresh object — re-acquires the HAL input
        do {
            try beginEngineLocked()
            recordRecovery(reason: reason)
            log("ambient capture hardRecover ok")
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
        teardownEngineLocked(finalize: true)
        engine = AVAudioEngine()
        do {
            try beginEngineLocked()
            recordRecovery(reason: "device changed")
            log("ambient capture mic device applied")
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
        teardownEngineLocked(finalize: false)
        log("ambient capture WEDGE SIMULATED (engine torn down, state left .capturing)")
    }

    private func recordRecovery(reason: String) {
        livenessLock.lock()
        _recoveryCount += 1
        _lastRecoveryAt = Date()
        _lastRecoveryReason = reason
        _lastTapAt = Date()   // give the fresh engine the staleness window before re-flagging
        livenessLock.unlock()
    }

    // MARK: - Engine (lock held)

    private func beginEngineLocked() throws {
        let input = engine.inputNode
        let requestedDeviceID = applyPreferredDeviceLocked(to: input)
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AmbientCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no input format (mic unavailable)"])
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: recordFormat) else {
            throw NSError(domain: "AmbientCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot build audio converter"])
        }
        converter = conv
        try openNewChunkLocked()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.handleTap(buffer, at: time)
        }
        engine.prepare()
        try engine.start()
        try verifyInputDeviceLocked(input, requested: requestedDeviceID)
        installConfigurationChangeObserverLocked()
    }

    /// After start, confirm the engine is on the device that was requested.
    ///
    /// The set before start succeeds and is then undone: the engine has been
    /// observed moving itself back onto the default-device aggregate, which on a
    /// Mac with AirPods connected is the AirPods microphone -- and merely
    /// opening that input drops AirPods output into hands-free mono. One
    /// re-apply is allowed. If the engine still will not stay put, it is torn
    /// down and the start fails loudly, because recording from the wrong
    /// microphone in silence is the failure this exists to prevent.
    private func verifyInputDeviceLocked(_ input: AVAudioInputNode, requested: AudioDeviceID?) throws {
        guard let requested else {
            observeInputDeviceLocked(input)
            return
        }
        guard observeInputDeviceLocked(input) else {
            log("ambient capture input verified: \(actualInputDescription())")
            return
        }
        log("ambient capture input drifted after start to \(actualInputDescription()); re-applying selected mic")
        engine.stop()
        applyDeviceIDLocked(requested, to: input)
        try engine.start()
        guard observeInputDeviceLocked(input) else {
            log("ambient capture input re-applied: \(actualInputDescription())")
            return
        }
        let actual = actualInputDescription()
        teardownEngineLocked(finalize: false)
        throw NSError(domain: "AmbientCapture", code: 3,
                      userInfo: [NSLocalizedDescriptionKey:
                                 "selected mic not honoured by the audio engine (engine is on \(actual)); refusing to record from the wrong input"])
    }

    /// Read back the engine's live input device and record it. Returns true
    /// when a device was requested and the engine is not on it.
    @discardableResult
    private func observeInputDeviceLocked(_ input: AVAudioInputNode) -> Bool {
        let actualID = Self.readCurrentDeviceID(from: input)
        let actualUID = actualID.flatMap(MicrophoneDeviceService.resolveAudioDeviceUID)
        let actualName = actualID.flatMap(MicrophoneDeviceService.resolveAudioDeviceName)
        livenessLock.lock()
        _actualInputDeviceUID = actualUID
        _actualInputDeviceName = actualName
        let requestedUID = _requestedInputDeviceUID
        livenessLock.unlock()
        return Self.classifyDeviceApplication(requestedUID: requestedUID, actualUID: actualUID) == .drifted
    }

    private static func readCurrentDeviceID(from input: AVAudioInputNode) -> AudioDeviceID? {
        guard let audioUnit = input.audioUnit else { return nil }
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    // MARK: - Engine configuration changes

    /// The engine posts this when the audio configuration changes underneath it
    /// -- a Bluetooth headset connecting is the common case -- and stops itself.
    /// Recover promptly on a fresh engine so the selected microphone is
    /// re-applied and verified, instead of waiting for tap staleness to notice
    /// half a minute later. Observed per engine instance, so a recovered engine
    /// gets its own.
    private func installConfigurationChangeObserverLocked() {
        removeConfigurationChangeObserverLocked()
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleConfigurationRecover()
        }
    }

    private func removeConfigurationChangeObserverLocked() {
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationChangeObserver = nil
        configurationLock.lock()
        pendingConfigurationRecover?.cancel()
        pendingConfigurationRecover = nil
        configurationLock.unlock()
    }

    /// Coalesced, because one headset connection posts several changes, and
    /// re-evaluated rather than acted on blindly: a change that left the engine
    /// running on the right device needs nothing, and recovering anyway would
    /// restart the engine for every change it posts about itself.
    private func scheduleConfigurationRecover() {
        let work = DispatchWorkItem { [weak self] in
            self?.recoverIfConfigurationChangeHurt()
        }
        configurationLock.lock()
        pendingConfigurationRecover?.cancel()
        pendingConfigurationRecover = work
        configurationLock.unlock()
        configurationQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func recoverIfConfigurationChangeHurt() {
        lock.lock()
        guard state == .capturing else { lock.unlock(); return }
        let stopped = !engine.isRunning
        let drifted = observeInputDeviceLocked(engine.inputNode)
        lock.unlock()
        guard stopped || drifted else { return }
        autoRecover(reason: stopped
            ? "engine configuration change stopped the engine"
            : "engine configuration change moved the input to \(actualInputDescription())")
    }

    private func actualInputDescription() -> String {
        livenessLock.lock(); defer { livenessLock.unlock() }
        let name = _actualInputDeviceName ?? "unknown"
        let uid = _actualInputDeviceUID ?? "?"
        return "\(name) [\(uid)]"
    }

    static func resolvePreferredDeviceIDForCapture(
        uid: String?,
        resolver: (String) -> AudioDeviceID?,
        log: (String) -> Void
    ) -> AudioDeviceID? {
        guard let uid, !uid.isEmpty else { return nil }
        guard let deviceID = resolver(uid) else {
            log("ambient capture selected mic not found; using system default")
            return nil
        }
        return deviceID
    }

    /// Returns the device that was requested, or nil when none applies: nothing
    /// selected, or the selection is not present. That nil is the fail-soft path
    /// that has always existed -- the system default is used on purpose and is
    /// never reported as drift.
    private func applyPreferredDeviceLocked(to input: AVAudioInputNode) -> AudioDeviceID? {
        guard let deviceID = Self.resolvePreferredDeviceIDForCapture(
            uid: preferredDeviceUID,
            resolver: resolveAudioDeviceID,
            log: log
        ) else {
            livenessLock.lock(); _requestedInputDeviceUID = nil; livenessLock.unlock()
            return nil
        }
        livenessLock.lock(); _requestedInputDeviceUID = preferredDeviceUID; livenessLock.unlock()
        applyDeviceIDLocked(deviceID, to: input)
        return deviceID
    }

    private func applyDeviceIDLocked(_ deviceID: AudioDeviceID, to input: AVAudioInputNode) {
        var deviceID = deviceID
        guard let audioUnit = input.audioUnit else {
            log("ambient capture input audio unit unavailable; selected mic cannot be applied")
            return
        }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            log("ambient capture selected mic apply failed status=\(status)")
        }
    }

    private func teardownEngineLocked(finalize: Bool) {
        removeConfigurationChangeObserverLocked()
        livenessLock.lock()
        _requestedInputDeviceUID = nil
        _actualInputDeviceUID = nil
        _actualInputDeviceName = nil
        livenessLock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        if finalize { finalizeChunkLocked() }
        converter = nil
        overlapTail.removeAll()
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

    private func handleTap(_ buffer: AVAudioPCMBuffer, at tapTime: AVAudioTime?) {
        recordTap()   // engine delivered a buffer — liveness proof, even before conversion
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
            if framesInCurrentChunk >= chunkFrameLimit {
                _ = finalizeChunkLocked()
                try openNewChunkLocked()
                let primedFrames = primeOverlapLocked()
                currentChunkTiming.markPrimeResult(primedFrames)
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

    /// Prepend the retained tail to a freshly opened chunk (3s overlap).
    private func primeOverlapLocked() -> AVAudioFrameCount {
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
