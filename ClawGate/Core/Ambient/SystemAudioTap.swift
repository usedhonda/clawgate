import AVFoundation
import CoreAudio
import Foundation

/// Records outgoing Mac audio independently of the microphone, including calls
/// outside Chrome, through a Core Audio tap. The two sources are never mixed.
///
/// Threading: the HAL calls the IOProc block synchronously inside its I/O cycle, so
/// the block only copies samples into a preallocated ring. A timer on `writerQueue`
/// drains it; that queue confines conversion, disk writes and writer fields. HAL calls (create/start/stop/destroy) run on `controlQueue` and
/// are never made while holding `stateLock` -- a HAL call made under a lock has
/// hung indefinitely before (see the AVAudioEngine incident).
final class SystemAudioTap {
    enum TapState: String { case idle, running, failed }

    enum TapError: Error, CustomStringConvertible {
        case unsupportedOS
        case noChromeProcess
        case osStatus(String, OSStatus)
        case badFormat
        case releaseFailed

        var description: String {
            switch self {
            case .unsupportedOS: return "process taps need macOS 14.2 or later"
            case .noChromeProcess: return "no Chrome audio process"
            case .osStatus(let step, let status): return "\(step) failed (\(status))"
            case .badFormat: return "tap format unusable"
            case .releaseFailed: return "could not release Core Audio objects"
            }
        }
    }

    var onChunkReady: ((AmbientCaptureManager.CompletedChunk) -> Void)?

    private let log: (String) -> Void
    private let chunkFrames: AVAudioFrameCount
    private let overlapFrames: Int
    private let controlQueue = DispatchQueue(label: "ai.clawgate.ambient.systemtap.control")
    private let ioQueue = DispatchQueue(label: "ai.clawgate.ambient.systemtap.io", qos: .userInteractive)
    private let writerQueue = DispatchQueue(label: "ai.clawgate.ambient.systemtap.writer", qos: .utility)
    /// A stalled disk loses audio past this point, not the HAL cycle.
    private static let ringSeconds = 30
    private static let drainMilliseconds = 100
    private var ring: AudioFrameRing?
    private var drainTimer: DispatchSourceTimer?
    private var drainBuffer: AVAudioPCMBuffer?
    private var drainFormat: AVAudioFormat?
    private var droppedBytesSeen = 0
    private var writeFailing = false

    // HAL objects, touched only on controlQueue.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedProcesses: [AudioObjectID] = []

    // Observable state, guarded by stateLock (plain assignments only).
    private let stateLock = NSLock()
    private var _state: TapState = .idle
    private var _chunksSurfaced = 0
    private var _lastChunkAt: Date?
    private var _lastError: String?
    // IO diagnostics: tells "IOProc never fires" from "fires but nothing converts".
    private var _convertFailures = 0
    private var _ring: AudioFrameRing?
    private var _tapFormat = ""

    // Writer state, confined to writerQueue.
    private let recordFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var chunkSeq = 0
    private var framesInChunk: AVAudioFrameCount = 0
    private var liveFramesInChunk: AVAudioFrameCount = 0
    private var primedFrames: AVAudioFrameCount = 0
    private var firstLiveSampleAt: Date?
    private var sumSquares = 0.0
    private var overlapTail: [Float] = []
    private var chunker = UtteranceChunker(forcedOverlapSeconds: 1)

    init(chunkSeconds: Int = 30, overlapSeconds: Int = 3, log: @escaping (String) -> Void) {
        self.chunkFrames = AVAudioFrameCount(max(5, chunkSeconds) * 16_000)
        self.overlapFrames = max(0, overlapSeconds) * 16_000
        self.log = log
    }

    var state: TapState { stateLock.withLock { _state } }
    var chunksSurfaced: Int { stateLock.withLock { _chunksSurfaced } }
    var lastChunkAt: Date? { stateLock.withLock { _lastChunkAt } }
    var lastError: String? { stateLock.withLock { _lastError } }
    var diagnostics: String {
        stateLock.withLock {
            let io = _ring?.snapshot ?? AudioFrameRing.Counters()
            return "callbacks=\(io.callbacks) buffers=\(io.bufferCount) framesIn=\(io.framesIn) droppedBytes=\(io.droppedBytes) wrapFail=\(io.wrapFailures) convertFail=\(_convertFailures) format=\(_tapFormat)"
        }
    }

    /// Converge on the wanted state. Asynchronous: the caller never waits on
    /// Core Audio. A global tap does not need app-specific process discovery.
    func setActive(_ active: Bool) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            if active {
                if self.procID != nil { return }
                do {
                    guard self.teardown() else { throw TapError.releaseFailed }
                    try self.startTap()
                    self.setState(.running, error: nil)
                    self.log("ambient system tap started")
                } catch {
                    _ = self.teardown()
                    self.setState(.failed, error: "\(error)")
                    self.log("ambient system tap start failed: \(error)")
                }
            } else if self.procID != nil || self.aggregateID != kAudioObjectUnknown || self.tapID != kAudioObjectUnknown {
                guard self.teardown() else {
                    // Held handles are retried by the next reconcile; this is not "stopped".
                    self.setState(.failed, error: "\(TapError.releaseFailed)")
                    self.log("ambient system tap release failed")
                    return
                }
                self.setState(.idle, error: nil)
                self.log("ambient system tap stopped")
            } else if self.state == .failed {
                self.setState(.idle, error: nil)
            }
        }
    }

    private func setState(_ state: TapState, error: String?) {
        stateLock.withLock {
            _state = state
            _lastError = error
        }
    }

    // MARK: - HAL (controlQueue only)

    private func startTap() throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupportedOS }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "ClawGate system audio tap"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.osStatus("create process tap", status) }
        tapID = tap
        tappedProcesses = []

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw TapError.osStatus("read tap format", status) }
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else { throw TapError.badFormat }
        let formatText = "\(Int(asbd.mSampleRate))Hz ch=\(asbd.mChannelsPerFrame) flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel)"
        stateLock.withLock {
            _tapFormat = formatText
            _convertFailures = 0
        }

        let outputUID = Self.defaultOutputDeviceUID() ?? ""
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ClawGate system audio tap",
            kAudioAggregateDeviceUIDKey: "ai.clawgate.meettap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if !outputUID.isEmpty {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { throw TapError.osStatus("create aggregate device", status) }
        aggregateID = device

        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0, asbd.mSampleRate > 0 else { throw TapError.badFormat }
        let ring = AudioFrameRing(capacityBytes: Int(asbd.mSampleRate) * bytesPerFrame * Self.ringSeconds,
                                  bytesPerFrame: bytesPerFrame)
        let drainFrames = AVAudioFrameCount(asbd.mSampleRate) / 10
        guard let drainBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: drainFrames) else { throw TapError.badFormat }
        stateLock.withLock { _ring = ring }
        writerQueue.sync {
            self.resetWriter()
            self.startDrain(ring: ring, buffer: drainBuffer, format: tapFormat)
        }
        let channels = tapFormat.channelCount
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { _, input, _, _, _ in
            Self.copyInput(input, channels: channels, into: ring)
        }
        guard status == noErr, let proc else { throw TapError.osStatus("create IOProc", status) }
        procID = proc

        status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw TapError.osStatus("start device", status) }
    }

    /// Stop IO first, then destroy in reverse order of creation, then flush the
    /// open chunk so the tail of the call is not lost.
    /// A handle is only forgotten once Core Audio accepted its release, and nothing
    /// is destroyed underneath an object still using it. Returns false if any remain.
    @discardableResult
    private func teardown() -> Bool {
        if aggregateID != kAudioObjectUnknown, let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            if AudioDeviceDestroyIOProcID(aggregateID, proc) == noErr { procID = nil }
        }
        if procID == nil, aggregateID != kAudioObjectUnknown,
           AudioHardwareDestroyAggregateDevice(aggregateID) == noErr {
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if aggregateID == kAudioObjectUnknown, tapID != kAudioObjectUnknown, #available(macOS 14.2, *),
           AudioHardwareDestroyProcessTap(tapID) == noErr {
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tappedProcesses = []
        writerQueue.sync {
            self.stopDrain()
            self.finalizeChunk()
            self.resetWriter()
        }
        return procID == nil && aggregateID == kAudioObjectUnknown && tapID == kAudioObjectUnknown
    }

    // MARK: - Writer (writerQueue only)

    private func resetWriter() {
        converter = nil
        converterInput = nil
        file = nil
        fileURL = nil
        framesInChunk = 0
        liveFramesInChunk = 0
        primedFrames = 0
        firstLiveSampleAt = nil
        sumSquares = 0
        overlapTail = []
        chunker = UtteranceChunker(forcedOverlapSeconds: 1)
    }

    /// The aggregate carries the output device as its clock. When that device
    /// has a microphone (AirPods, a headset), its input stream arrives in the
    /// same list ahead of the tap. The tap's stream is the last buffer with its channels.
    private static func copyInput(_ input: UnsafePointer<AudioBufferList>, channels: AVAudioChannelCount,
                                  into ring: AudioFrameRing) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let tapBuffer = list.last(where: { $0.mNumberChannels == channels && $0.mDataByteSize > 0 })
        ring.write(tapBuffer?.mData, byteCount: Int(tapBuffer?.mDataByteSize ?? 0), bufferCount: list.count)
    }

    private func startDrain(ring: AudioFrameRing, buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        self.ring = ring
        drainBuffer = buffer
        drainFormat = format
        droppedBytesSeen = 0
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + .milliseconds(Self.drainMilliseconds),
                       repeating: .milliseconds(Self.drainMilliseconds), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    private func stopDrain() {
        drainTimer?.cancel()
        drainTimer = nil
        drain()
        ring = nil
        drainBuffer = nil
        drainFormat = nil
    }

    private func drain() {
        guard let ring, let buffer = drainBuffer, let format = drainFormat,
              let target = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let maxBytes = Int(buffer.frameCapacity) * bytesPerFrame
        // Audio was lost here, so a chunk must not claim to span the gap.
        let dropped = ring.snapshot.droppedBytes
        if dropped != droppedBytesSeen {
            droppedBytesSeen = dropped
            finalizeChunk()
            log("ambient system tap dropped audio; total bytes=\(dropped)")
        }
        while true {
            let bytes = ring.read(into: target, maxBytes: maxBytes)
            guard bytes > 0 else { return }
            buffer.frameLength = AVAudioFrameCount(bytes / bytesPerFrame)
            convertAndWrite(buffer, format: format, arrivedAt: Date())
        }
    }

    private func convertAndWrite(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat, arrivedAt: Date) {
        if converter == nil || converterInput != format {
            converter = AVAudioConverter(from: format, to: recordFormat)
            converterInput = format
        }
        guard let converter else { return }
        let ratio = recordFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if consumed { inStatus.pointee = .noDataNow; return nil }
            consumed = true
            inStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else {
            stateLock.withLock { _convertFailures += 1 }
            return
        }
        write(out, arrivedAt: arrivedAt)
    }

    private func write(_ buffer: AVAudioPCMBuffer, arrivedAt: Date) {
        do {
            if file == nil { try openChunk() }
            // Not bound locally: finalizeChunk below must be able to release the
            // file so its WAV header is complete before the chunk is handed on.
            guard file != nil else { return }
            try file?.write(from: buffer)
            writeFailing = false
            let n = Int(buffer.frameLength)
            if firstLiveSampleAt == nil {
                firstLiveSampleAt = arrivedAt.addingTimeInterval(-Double(n) / 16_000)
            }
            framesInChunk += buffer.frameLength
            liveFramesInChunk += buffer.frameLength
            if let samples = buffer.floatChannelData?[0] {
                var sum = 0.0
                for i in 0..<n { let v = Double(samples[i]); sum += v * v }
                sumSquares += sum
                if overlapFrames > 0 {
                    overlapTail.append(contentsOf: UnsafeBufferPointer(start: samples, count: n))
                    if overlapTail.count > overlapFrames {
                        overlapTail.removeFirst(overlapTail.count - overlapFrames)
                    }
                }
            }
            var cut = framesInChunk >= chunkFrames
            var overlapLimit = overlapFrames
            if let samples = buffer.floatChannelData?[0],
               case .cut(let overlap) = chunker.consume(UnsafeBufferPointer(start: samples, count: n)) {
                cut = true
                overlapLimit = overlap
            }
            if cut {
                finalizeChunk()
                try openChunk()
                primeOverlap(limit: overlapLimit)
                chunker.didStartChunk(primed: Int(primedFrames))
            }
        } catch {
            if !writeFailing { log("ambient system tap write error: \(error)") }
            writeFailing = true
            stateLock.withLock { _convertFailures += 1 }
        }
    }

    private func openChunk() throws {
        chunkSeq += 1
        let dir = AmbientStorage.rollingDir(for: Date())
        AmbientStorage.ensureDir(dir)
        let url = dir.appendingPathComponent(String(format: "system-chunk-%06d.wav", chunkSeq))
        file = try AVAudioFile(forWriting: url, settings: fileSettings)
        fileURL = url
        framesInChunk = 0
        liveFramesInChunk = 0
        primedFrames = 0
        firstLiveSampleAt = nil
        sumSquares = 0
    }

    /// Lead the new chunk with the previous chunk's tail: none after a pause cut,
    /// a little after a forced cut in continuous speech.
    private func primeOverlap(limit: Int) {
        if limit < overlapTail.count {
            overlapTail.removeFirst(overlapTail.count - max(0, limit))
        }
        guard overlapFrames > 0, !overlapTail.isEmpty, let file,
              let buffer = AVAudioPCMBuffer(pcmFormat: recordFormat,
                                            frameCapacity: AVAudioFrameCount(overlapTail.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        overlapTail.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: src.count)
        }
        buffer.frameLength = AVAudioFrameCount(overlapTail.count)
        do {
            try file.write(from: buffer)
            framesInChunk += buffer.frameLength
            primedFrames = buffer.frameLength
        } catch {
            log("ambient system tap overlap write error: \(error)")
        }
    }

    private func finalizeChunk() {
        guard let url = fileURL else { return }
        let live = liveFramesInChunk
        let total = framesInChunk
        let primed = primedFrames
        let squares = sumSquares
        let firstLive = firstLiveSampleAt
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
        fileURL = nil
        guard live > 16_000, total > 0 else {  // under ~1s of new audio
            try? FileManager.default.removeItem(at: url)
            return
        }
        let rms = Float((squares / Double(live)).squareRoot())
        // The chunk begins with the primed overlap, so its first sample is that
        // much earlier than the first live sample.
        let startedAt = firstLive?.addingTimeInterval(-Double(primed) / 16_000)
        let chunk = AmbientCaptureManager.CompletedChunk(
            url: url,
            sequence: chunkSeq,
            rms: rms,
            startedAt: startedAt,
            actualPrimedFrames: primed,
            sampleRate: 16_000,
            provenOverlap: primed > 0,
            source: .system
        )
        stateLock.withLock {
            _chunksSurfaced += 1
            _lastChunkAt = Date()
        }
        let callback = onChunkReady
        DispatchQueue.global(qos: .utility).async { callback?(chunk) }
    }

    // MARK: - Core Audio queries

    static func chromeProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { bundleID(of: $0)?.hasPrefix("com.google.Chrome") == true }
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        stringProperty(process, selector: kAudioProcessPropertyBundleID)
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        return stringProperty(device, selector: kAudioDevicePropertyDeviceUID)
    }

    /// True when sound currently comes out of the Mac's own speakers, where the
    /// remote party leaks back into the microphone. The headphone jack shares the
    /// built-in device, so the data source tells speakers from headphones.
    static func outputIsBuiltInSpeaker() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var source: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr else {
            return true  // built-in with no data source reported: treat as speakers
        }
        return source != fourCC("hdpn")
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
