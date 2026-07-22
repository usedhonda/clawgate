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
    /// Wall-clock time the current chunk started (for absolute segment times).
    private var chunkStartedAt = Date()
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
    private var preferredDeviceUID: String?
    private let resolveAudioDeviceID: (String) -> AudioDeviceID?

    /// Snapshot of capture liveness for /v1/ambient/status, the doctor check,
    /// and the in-app health monitor.
    struct Liveness {
        var lastTapAt: Date?
        var lastChunkReadyAt: Date?
        var chunksSurfaced: Int
        var recoveryCount: Int
        var lastRecoveryAt: Date?
        var lastRecoveryReason: String?
    }

    func livenessSnapshot() -> Liveness {
        livenessLock.lock(); defer { livenessLock.unlock() }
        return Liveness(lastTapAt: _lastTapAt,
                        lastChunkReadyAt: _lastChunkReadyAt,
                        chunksSurfaced: _chunksSurfaced,
                        recoveryCount: _recoveryCount,
                        lastRecoveryAt: _lastRecoveryAt,
                        lastRecoveryReason: _lastRecoveryReason)
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
    /// Arguments: file URL, RMS level (0…1, measured during capture so the
    /// silence gate never re-reads the file), and the chunk's wall-clock start.
    var onChunkReady: ((URL, Float, Date) -> Void)?

    /// Optional per-buffer level meter (broadcast HUD). Invoked off the main
    /// thread with a throttled per-buffer RMS (~0…1). Entirely separate from the
    /// chunk RMS used by the silence gate — it never touches chunk state.
    var onLevel: ((Float) -> Void)?
    private let levelLock = NSLock()
    private var _lastLevelEmitAt = Date.distantPast

    private let log: (String) -> Void

    init(chunkSeconds: Int = 30,
         overlapSeconds: Int = 3,
         retentionSeconds: TimeInterval = 6 * 3600,
         resolveAudioDeviceID: @escaping (String) -> AudioDeviceID? = MicrophoneDeviceService.resolveAudioDeviceID,
         log: @escaping (String) -> Void = { _ in }) {
        self.chunkSeconds = max(5, chunkSeconds)
        self.overlapFrames = max(0, overlapSeconds) * 16_000
        self.retentionSeconds = retentionSeconds
        self.resolveAudioDeviceID = resolveAudioDeviceID
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
        applyPreferredDeviceLocked(to: input)
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

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        engine.prepare()
        try engine.start()
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

    private func applyPreferredDeviceLocked(to input: AVAudioInputNode) {
        guard var deviceID = Self.resolvePreferredDeviceIDForCapture(
            uid: preferredDeviceUID,
            resolver: resolveAudioDeviceID,
            log: log
        ) else { return }
        guard let audioUnit = input.audioUnit else {
            log("ambient capture input audio unit unavailable; using system default")
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
            log("ambient capture selected mic apply failed status=\(status); using system default")
        }
    }

    private func teardownEngineLocked(finalize: Bool) {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        if finalize { finalizeChunkLocked() }
        converter = nil
        overlapTail.removeAll()
    }

    // MARK: - Chunk files (lock held except onChunkReady dispatch)

    private func openNewChunkLocked() throws {
        let dir = AmbientStorage.rollingDir(for: Date())
        AmbientStorage.ensureDir(dir)
        chunkSeq += 1
        let name = String(format: "chunk-%06d.wav", chunkSeq)
        let url = dir.appendingPathComponent(name)
        currentFile = try AVAudioFile(forWriting: url, settings: fileSettings)
        currentChunkURL = url
        framesInCurrentChunk = 0
        sumSquaresInCurrentChunk = 0
        chunkStartedAt = Date()
    }

    private func finalizeChunkLocked() {
        guard let url = currentChunkURL else { return }
        let frames = framesInCurrentChunk
        let sumSquares = sumSquaresInCurrentChunk
        let startedAt = chunkStartedAt
        currentFile = nil
        currentChunkURL = nil
        framesInCurrentChunk = 0
        sumSquaresInCurrentChunk = 0
        // Only surface chunks with real audio (skip empty stubs).
        guard frames > 16_000 else {  // < ~1s of audio
            try? FileManager.default.removeItem(at: url)
            return
        }
        let rms = Float((sumSquares / Double(frames)).squareRoot())
        recordChunkReady()   // a real chunk was finalized (incl. silence chunks — silence-safe liveness)
        let cb = onChunkReady
        let retain = retentionSeconds
        DispatchQueue.global(qos: .utility).async {
            cb?(url, rms, startedAt)
            AmbientStorage.pruneRolling(olderThan: retain)
        }
    }

    // MARK: - Audio thread

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        recordTap()   // engine delivered a buffer — liveness proof, even before conversion
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

        emitLevelIfNeeded(outBuf)

        lock.lock(); defer { lock.unlock() }
        guard currentFile != nil else { return }
        writeBufferLocked(outBuf)
    }

    // MARK: - Write + overlap (lock held)

    private func writeBufferLocked(_ buf: AVAudioPCMBuffer) {
        guard let file = currentFile else { return }
        do {
            try file.write(from: buf)
            framesInCurrentChunk += buf.frameLength
            accumulateSumSquares(buf)
            appendOverlapTail(buf)
            if framesInCurrentChunk >= chunkFrameLimit {
                finalizeChunkLocked()
                try openNewChunkLocked()
                primeOverlapLocked()
            }
        } catch {
            log("ambient capture write error: \(error)")
        }
    }

    /// Compute a throttled (~10 Hz) per-buffer RMS and hand it to the level
    /// meter. Independent of the chunk RMS accumulation.
    private func emitLevelIfNeeded(_ buf: AVAudioPCMBuffer) {
        guard let onLevel else { return }
        let now = Date()
        levelLock.lock()
        let due = now.timeIntervalSince(_lastLevelEmitAt) >= 0.1
        if due { _lastLevelEmitAt = now }
        levelLock.unlock()
        guard due, let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        var sum = 0.0
        for i in 0..<n { let v = Double(ch[0][i]); sum += v * v }
        let rms = Float((sum / Double(n)).squareRoot())
        onLevel(rms)
    }

    /// Accumulate squared sample energy for the current chunk's RMS.
    private func accumulateSumSquares(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        var sum = 0.0
        for i in 0..<n { let v = Double(ch[0][i]); sum += v * v }
        sumSquaresInCurrentChunk += sum
    }

    /// Keep the most recent `overlapFrames` Float samples for the next chunk.
    private func appendOverlapTail(_ buf: AVAudioPCMBuffer) {
        guard overlapFrames > 0, let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        overlapTail.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        if overlapTail.count > overlapFrames {
            overlapTail.removeFirst(overlapTail.count - overlapFrames)
        }
    }

    /// Prepend the retained tail to a freshly opened chunk (3s overlap).
    private func primeOverlapLocked() {
        guard overlapFrames > 0, !overlapTail.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: recordFormat,
                                         frameCapacity: AVAudioFrameCount(overlapTail.count)),
              let ch = buf.floatChannelData else { return }
        let n = overlapTail.count
        for i in 0..<n { ch[0][i] = overlapTail[i] }
        buf.frameLength = AVAudioFrameCount(n)
        do {
            try currentFile?.write(from: buf)
            framesInCurrentChunk += buf.frameLength
            accumulateSumSquares(buf)
        } catch {
            log("ambient overlap prime error: \(error)")
        }
    }
}
