import AVFoundation
import CoreAudio
import Foundation

/// Records what Chrome plays -- the remote party of a Google Meet call -- through
/// a Core Audio process tap, into the same 16 kHz mono chunk files (30s chunks,
/// 3s overlap) the microphone path produces. Meet never plays the owner's own
/// voice back to them, so everything this tap hears is the other party.
///
/// Threading: every writer field is confined to `ioQueue`, where the IOProc
/// block runs. HAL calls (create/start/stop/destroy) run on `controlQueue` and
/// are never made while holding `stateLock` -- a HAL call made under a lock has
/// hung indefinitely before (see the AVAudioEngine incident).
final class SystemAudioTap {
    enum TapState: String { case idle, running, failed }

    enum TapError: Error, CustomStringConvertible {
        case unsupportedOS
        case noChromeProcess
        case osStatus(String, OSStatus)
        case badFormat

        var description: String {
            switch self {
            case .unsupportedOS: return "process taps need macOS 14.2 or later"
            case .noChromeProcess: return "no Chrome audio process"
            case .osStatus(let step, let status): return "\(step) failed (\(status))"
            case .badFormat: return "tap format unusable"
            }
        }
    }

    var onChunkReady: ((AmbientCaptureManager.CompletedChunk) -> Void)?

    private let log: (String) -> Void
    private let chunkFrames: AVAudioFrameCount
    private let overlapFrames: Int
    private let controlQueue = DispatchQueue(label: "ai.clawgate.ambient.systemtap.control")
    private let ioQueue = DispatchQueue(label: "ai.clawgate.ambient.systemtap.io")

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
    private var _ioCallbacks = 0
    private var _framesIn = 0
    private var _wrapFailures = 0
    private var _convertFailures = 0
    private var _tapFormat = ""

    // Writer state, confined to ioQueue.
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
            "callbacks=\(_ioCallbacks) framesIn=\(_framesIn) wrapFail=\(_wrapFailures) convertFail=\(_convertFailures) format=\(_tapFormat)"
        }
    }

    /// Converge on the wanted state. Asynchronous: the caller never waits on
    /// Core Audio. While running, a changed set of Chrome audio processes (Chrome
    /// can respawn its audio service) rebuilds the tap.
    func setActive(_ active: Bool) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            if active {
                let current = Self.chromeProcessObjects()
                if self.procID != nil {
                    guard Set(current) != Set(self.tappedProcesses) else { return }
                    self.log("ambient system tap: Chrome audio processes changed, rebuilding")
                    self.teardown()
                }
                do {
                    try self.startTap(processes: current)
                    self.setState(.running, error: nil)
                    self.log("ambient system tap started processes=\(current.count)")
                } catch {
                    self.teardown()
                    self.setState(.failed, error: "\(error)")
                    self.log("ambient system tap start failed: \(error)")
                }
            } else if self.procID != nil || self.tapID != kAudioObjectUnknown {
                self.teardown()
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

    private func startTap(processes: [AudioObjectID]) throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupportedOS }
        guard !processes.isEmpty else { throw TapError.noChromeProcess }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "ClawGate Meet tap"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.osStatus("create process tap", status) }
        tapID = tap
        tappedProcesses = processes

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
        let formatText = "\(Int(asbd.mSampleRate))Hz ch=\(asbd.mChannelsPerFrame) flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel) procs=\(processes.count)"
        stateLock.withLock {
            _tapFormat = formatText
            _ioCallbacks = 0; _framesIn = 0; _wrapFailures = 0; _convertFailures = 0
        }

        let outputUID = Self.defaultOutputDeviceUID() ?? ""
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ClawGate Meet tap",
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

        ioQueue.sync { self.resetWriter() }
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { [weak self] _, input, _, _, _ in
            self?.handleInput(input, format: tapFormat)
        }
        guard status == noErr, let proc else { throw TapError.osStatus("create IOProc", status) }
        procID = proc

        status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw TapError.osStatus("start device", status) }
    }

    /// Stop IO first, then destroy in reverse order of creation, then flush the
    /// open chunk so the tail of the call is not lost.
    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tappedProcesses = []
        ioQueue.sync {
            self.finalizeChunk()
            self.resetWriter()
        }
    }

    // MARK: - Writer (ioQueue only)

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

    private func handleInput(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        stateLock.withLock { _ioCallbacks += 1 }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else {
            stateLock.withLock { _wrapFailures += 1 }
            return
        }
        stateLock.withLock { _framesIn += Int(buffer.frameLength) }
        let arrivedAt = Date()
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
            guard let file else { return }
            try file.write(from: buffer)
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
            log("ambient system tap write error: \(error)")
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
