import Foundation
import AVFoundation

/// Captures microphone audio into rolling 16 kHz mono WAV chunks suitable for
/// whisper.cpp. Capture is independently controllable (start/pause/resume/stop)
/// so the user can stop recording at any moment from the menu bar — a hard
/// privacy requirement of the Ambient Context Stream design.
final class AmbientCaptureManager {
    enum CaptureState: String { case idle, capturing, paused }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let chunkFrameLimit: AVAudioFrameCount

    private var currentFile: AVAudioFile?
    private var currentChunkURL: URL?
    private var framesInCurrentChunk: AVAudioFrameCount = 0
    private var chunkSeq = 0

    private let lock = NSLock()
    private(set) var state: CaptureState = .idle

    let chunkSeconds: Int
    /// Called (off the audio thread) when a chunk file is finalized and ready.
    var onChunkReady: ((URL) -> Void)?
    private let log: (String) -> Void

    init(chunkSeconds: Int = 60, log: @escaping (String) -> Void = { _ in }) {
        self.chunkSeconds = max(10, chunkSeconds)
        self.log = log
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
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

    // MARK: - Engine (lock held)

    private func beginEngineLocked() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AmbientCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no input format (mic unavailable)"])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        try openNewChunkLocked()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func teardownEngineLocked(finalize: Bool) {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        if finalize { finalizeChunkLocked() }
        converter = nil
    }

    // MARK: - Chunk files (lock held except onChunkReady dispatch)

    private func openNewChunkLocked() throws {
        let dir = AmbientStorage.rollingDir(for: Date())
        AmbientStorage.ensureDir(dir)
        chunkSeq += 1
        let name = String(format: "chunk-%06d.wav", chunkSeq)
        let url = dir.appendingPathComponent(name)
        currentFile = try AVAudioFile(forWriting: url, settings: targetFormat.settings)
        currentChunkURL = url
        framesInCurrentChunk = 0
    }

    private func finalizeChunkLocked() {
        guard let url = currentChunkURL else { return }
        let frames = framesInCurrentChunk
        currentFile = nil
        currentChunkURL = nil
        framesInCurrentChunk = 0
        // Only surface chunks with real audio (skip empty stubs).
        guard frames > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let cb = onChunkReady
        DispatchQueue.global(qos: .utility).async { cb?(url) }
    }

    // MARK: - Audio thread

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var convErr: NSError?
        let status = converter.convert(to: outBuf, error: &convErr) { _, inStatus in
            if consumed { inStatus.pointee = .noDataNow; return nil }
            consumed = true
            inStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, outBuf.frameLength > 0 else { return }

        lock.lock(); defer { lock.unlock() }
        guard let file = currentFile else { return }
        do {
            try file.write(from: outBuf)
            framesInCurrentChunk += outBuf.frameLength
            if framesInCurrentChunk >= chunkFrameLimit {
                finalizeChunkLocked()
                try openNewChunkLocked()
            }
        } catch {
            log("ambient capture write error: \(error)")
        }
    }
}
