import Foundation
import AVFoundation

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

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    /// Buffer format handed to AVAudioFile.write — must match AVAudioFile.processingFormat.
    private let recordFormat: AVAudioFormat
    /// On-disk encoding (16-bit PCM mono 16 kHz) for whisper.cpp.
    private let fileSettings: [String: Any]
    private let chunkFrameLimit: AVAudioFrameCount
    /// Carry the last N samples into the next chunk so a sentence split across
    /// the boundary keeps context (matches the 3s overlap in the STT preset).
    private let overlapFrames: Int

    private var currentFile: AVAudioFile?
    private var currentChunkURL: URL?
    private var framesInCurrentChunk: AVAudioFrameCount = 0
    private var chunkSeq = 0
    private var overlapTail: [Float] = []

    private let lock = NSLock()
    private(set) var state: CaptureState = .idle

    let chunkSeconds: Int
    /// Called (off the audio thread) when a chunk file is finalized and ready.
    var onChunkReady: ((URL) -> Void)?
    private let log: (String) -> Void

    init(chunkSeconds: Int = 30, overlapSeconds: Int = 3, log: @escaping (String) -> Void = { _ in }) {
        self.chunkSeconds = max(5, chunkSeconds)
        self.overlapFrames = max(0, overlapSeconds) * 16_000
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

    // MARK: - Engine (lock held)

    private func beginEngineLocked() throws {
        let input = engine.inputNode
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
    }

    private func finalizeChunkLocked() {
        guard let url = currentChunkURL else { return }
        let frames = framesInCurrentChunk
        currentFile = nil
        currentChunkURL = nil
        framesInCurrentChunk = 0
        // Only surface chunks with real audio (skip empty stubs).
        guard frames > 16_000 else {  // < ~1s of audio
            try? FileManager.default.removeItem(at: url)
            return
        }
        let cb = onChunkReady
        DispatchQueue.global(qos: .utility).async { cb?(url) }
    }

    // MARK: - Audio thread

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
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
        writeBufferLocked(outBuf)
    }

    // MARK: - Write + overlap (lock held)

    private func writeBufferLocked(_ buf: AVAudioPCMBuffer) {
        guard let file = currentFile else { return }
        do {
            try file.write(from: buf)
            framesInCurrentChunk += buf.frameLength
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
        } catch {
            log("ambient overlap prime error: \(error)")
        }
    }
}
