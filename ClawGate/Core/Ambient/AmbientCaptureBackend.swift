import AVFoundation
import CoreMedia
import Foundation

/// Owns the microphone session for ambient capture and nothing else.
///
/// Built on AVCaptureSession rather than AVAudioEngine, and the reason is
/// measured, not stylistic: creating `AVAudioEngine.inputNode` binds to the
/// system default input before the caller can point it anywhere, and with a
/// Bluetooth headset as the default that single touch drops the headset into
/// hands-free mono for as long as the process lives. Moving the unit to the
/// built-in microphone afterwards does not undo it, and in that state the
/// engine delivered no audio at all. An AVCaptureDeviceInput is built on the
/// chosen device from the start and never touches the default; the headset
/// stayed in its stereo profile through configure, start, four seconds of
/// running, and stop (2026-09-02).
///
/// Everything here runs on one serial queue that no caller ever waits on.
/// `startRunning` and `stopRunning` block inside Core Audio, and during a
/// Bluetooth reconfiguration they can block for minutes; a control path that
/// waits on them takes every endpoint down with it. So the manager hands this
/// object a generation and a completion, and reads the result when it comes.
/// Anything that arrives for a generation the manager has since moved past is
/// dropped here and never reaches the chunk pipeline.
final class AmbientCaptureBackend: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    struct StartedInfo {
        let deviceUID: String
        let deviceName: String
        let sampleRate: Double
        let channels: Int
    }

    enum Event {
        case runtimeError(String)
        case interrupted
        case interruptionEnded
    }

    /// A delivered buffer. `time` carries the first sample's host time so the
    /// manager can date chunks the same way it always has.
    typealias BufferHandler = (_ generation: Int, _ buffer: AVAudioPCMBuffer, _ format: AVAudioFormat, _ time: AVAudioTime?) -> Void
    typealias EventHandler = (_ generation: Int, _ event: Event) -> Void

    private let queue = DispatchQueue(label: "ai.clawgate.ambient.capture-backend", qos: .userInitiated)
    private let deliveryQueue = DispatchQueue(label: "ai.clawgate.ambient.capture-delivery", qos: .userInitiated)
    private let log: (String) -> Void

    private var session: AVCaptureSession?
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureAudioDataOutput?
    private var observers: [NSObjectProtocol] = []

    /// The generation the live session belongs to. Read on the delivery queue
    /// for every buffer, written on the backend queue at start/stop; the lock
    /// keeps that handoff exact rather than eventually consistent.
    private let generationLock = NSLock()
    private var _liveGeneration = 0

    var onBuffer: BufferHandler?
    var onEvent: EventHandler?

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
        super.init()
    }

    // MARK: - Commands (asynchronous, never awaited by the caller)

    /// Open the requested device, or the system default when `deviceUID` is
    /// nil. The default is resolved once, here, to a concrete device; the
    /// session does not follow later default changes.
    func start(deviceUID: String?, generation: Int, completion: @escaping (Result<StartedInfo, Error>) -> Void) {
        queue.async { [self] in
            teardownLocked()
            do {
                let device = try Self.resolveDevice(uid: deviceUID)
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                session.beginConfiguration()
                guard session.canAddInput(input) else { throw BackendError.cannotAddInput(device.localizedName) }
                session.addInput(input)
                guard session.canAddOutput(output) else { throw BackendError.cannotAddOutput }
                session.addOutput(output)
                session.commitConfiguration()
                output.setSampleBufferDelegate(self, queue: deliveryQueue)

                self.session = session
                self.input = input
                self.output = output
                installObserversLocked(session: session, generation: generation)
                setLiveGeneration(generation)

                session.startRunning()   // blocks inside Core Audio; only this queue waits

                let format = device.activeFormat.formatDescription
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
                completion(.success(StartedInfo(
                    deviceUID: device.uniqueID,
                    deviceName: device.localizedName,
                    sampleRate: asbd?.mSampleRate ?? 0,
                    channels: Int(asbd?.mChannelsPerFrame ?? 0)
                )))
            } catch {
                teardownLocked()
                completion(.failure(error))
            }
        }
    }

    /// Stop and release the session. Buffers still in flight for this
    /// generation are dropped as soon as the generation is retired, which
    /// happens before `stopRunning` so nothing arrives during the stop.
    func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            teardownLocked()
            completion()
        }
    }

    // MARK: - Queue-confined internals

    private func teardownLocked() {
        setLiveGeneration(0)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let session {
            if session.isRunning { session.stopRunning() }
        }
        output?.setSampleBufferDelegate(nil, queue: nil)
        session = nil
        input = nil
        output = nil
    }

    private func installObserversLocked(session: AVCaptureSession, generation: Int) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.onEvent?(generation, .runtimeError(error?.localizedDescription ?? "unknown"))
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.onEvent?(generation, .interrupted)
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            self?.onEvent?(generation, .interruptionEnded)
        })
    }

    private func setLiveGeneration(_ generation: Int) {
        generationLock.lock(); _liveGeneration = generation; generationLock.unlock()
    }

    private var liveGeneration: Int {
        generationLock.lock(); defer { generationLock.unlock() }
        return _liveGeneration
    }

    // MARK: - Device resolution

    enum BackendError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case noDefaultInput
        case cannotAddInput(String)
        case cannotAddOutput
        var description: String {
            switch self {
            case .deviceNotFound(let uid): return "selected mic not found: \(uid)"
            case .noDefaultInput: return "no default audio input device"
            case .cannotAddInput(let name): return "cannot add input \(name) to capture session"
            case .cannotAddOutput: return "cannot add audio output to capture session"
            }
        }
    }

    static func resolveDevice(uid: String?) throws -> AVCaptureDevice {
        if let uid, !uid.isEmpty {
            let types: [AVCaptureDevice.DeviceType]
            if #available(macOS 14.0, *) { types = [.microphone, .external] } else { types = [.builtInMicrophone, .externalUnknown] }
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
            guard let device = devices.first(where: { $0.uniqueID == uid }) else { throw BackendError.deviceNotFound(uid) }
            return device
        }
        guard let device = AVCaptureDevice.default(for: .audio) else { throw BackendError.noDefaultInput }
        return device
    }

    // MARK: - Delivery

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let generation = liveGeneration
        guard generation != 0 else { return }
        guard let (buffer, format) = Self.pcmBuffer(from: sampleBuffer) else { return }
        onBuffer?(generation, buffer, format, Self.hostTime(of: sampleBuffer))
    }

    /// Whether a buffer stamped with `bufferGeneration` may enter the pipeline
    /// while `liveGeneration` is current. Pure, so the gate is testable: a
    /// retired generation, or a backend with no live session, delivers nothing.
    static func shouldDeliver(bufferGeneration: Int, liveGeneration: Int) -> Bool {
        liveGeneration != 0 && bufferGeneration == liveGeneration
    }

    /// Wrap the sample buffer's audio without copying. The format is whatever
    /// the device produces; the manager's converter takes it from there.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> (AVAudioPCMBuffer, AVAudioFormat)? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let bufferListSize = MemoryLayout<AudioBufferList>.size + (Int(asbd.mChannelsPerFrame) - 1) * MemoryLayout<AudioBuffer>.size
        let listPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { listPointer.deallocate() }
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: max(bufferListSize, MemoryLayout<AudioBufferList>.size),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        // Copy into an owned buffer: the block buffer is released when this
        // returns, and the manager converts on another thread later.
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        let source = UnsafeMutableAudioBufferListPointer(listPointer)
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for (index, sourceBuffer) in source.enumerated() where index < destination.count {
            let bytes = Int(min(sourceBuffer.mDataByteSize, destination[index].mDataByteSize))
            if let from = sourceBuffer.mData, let to = destination[index].mData {
                memcpy(to, from, bytes)
            }
        }
        return (pcm, format)
    }

    /// The capture session's clock is the host clock on macOS, so the
    /// presentation timestamp maps straight onto mach host time and the
    /// manager can date it with the same arithmetic it used for engine taps.
    private static func hostTime(of sampleBuffer: CMSampleBuffer) -> AVAudioTime? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return nil }
        let nanos = UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000_000)
        return AVAudioTime(hostTime: AudioConvertNanosToHostTime(nanos))
    }
}
