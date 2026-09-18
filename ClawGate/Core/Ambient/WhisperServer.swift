import Foundation

/// Keeps one whisper.cpp `whisper-server` resident so short, pause-aligned
/// chunks do not each pay a model load (large-v3-turbo on Metal). Launched with
/// the same flags `whisper-cli` gets, so its output matches the CLI path, which
/// remains the fallback whenever the server is absent, starting, or failing.
///
/// The server ships with its own ggml/whisper dylibs under `whisper/server/`
/// (built from the matching whisper.cpp tag), apart from the CLI's `lib/`.
final class WhisperServer {
    static let port = 8791
    static var root: URL { AmbientStorage.whisperRoot.appendingPathComponent("server", isDirectory: true) }
    static var binary: URL { root.appendingPathComponent("bin/whisper-server") }
    private static var pidFile: URL { root.appendingPathComponent("whisper-server.pid") }

    private let lock = NSLock()
    private var process: Process?
    private var readyAt: Date?
    private var startedAt: Date?
    private var consecutiveFailures = 0
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.binary.path) }

    /// Transcribe through the server, or nil when it cannot serve right now (the
    /// caller then uses whisper-cli). Never blocks on a server that is still
    /// loading the model.
    func transcribe(chunk: URL, model: URL, preset: AmbientPreset, prompt: String,
                    language: String?) -> [TranscriptSegment]? {
        guard isInstalled, ensureRunning(model: model, preset: preset, prompt: prompt, language: language) else {
            return nil
        }
        do {
            let segments = try post(chunk: chunk)
            lock.withLock { consecutiveFailures = 0 }
            return segments
        } catch {
            let failures = lock.withLock { () -> Int in consecutiveFailures += 1; return consecutiveFailures }
            log("whisper-server request failed (\(failures)): \(error)")
            if failures >= 3 { stop() }   // restart on the next chunk
            return nil
        }
    }

    func stop() {
        lock.withLock {
            process?.terminate()
            process = nil
            readyAt = nil
            startedAt = nil
            consecutiveFailures = 0
        }
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    // MARK: - Lifecycle

    private func ensureRunning(model: URL, preset: AmbientPreset, prompt: String, language: String?) -> Bool {
        lock.lock()
        if let process, process.isRunning {
            if readyAt != nil { lock.unlock(); return true }
            lock.unlock()
            return probeReady()
        }
        process = nil
        readyAt = nil
        lock.unlock()

        Self.killOrphan()
        let proc = Process()
        proc.executableURL = Self.binary
        var args = [
            "-m", model.path,
            "--host", "127.0.0.1", "--port", "\(Self.port)",
            "-l", language ?? "auto",
            "-t", "\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))",
            "-mc", "\(preset.maxContext)",
            "-bs", "\(preset.beamSize)",
            "-nth", "\(preset.noSpeechThreshold)",
            "-et", "\(preset.entropyThreshold)",
            "--prompt", prompt,
        ]
        if preset.suppressNonSpeech { args.append("-sns") }
        let vadModel = AmbientStorage.defaultVADModel
        if preset.vad, FileManager.default.fileExists(atPath: vadModel.path) {
            args.append(contentsOf: ["--vad", "-vm", vadModel.path])
        }
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            log("whisper-server launch failed: \(error)")
            return false
        }
        try? "\(proc.processIdentifier)".write(to: Self.pidFile, atomically: true, encoding: .utf8)
        lock.withLock {
            process = proc
            startedAt = Date()
        }
        log("whisper-server launched pid=\(proc.processIdentifier)")
        return probeReady()
    }

    /// Ready once the HTTP port answers. While the model is still loading this
    /// chunk goes to the CLI; a server that never comes up is abandoned.
    private func probeReady() -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/")!)
        request.timeoutInterval = 1
        let ok = Self.send(request, timeout: 2) != nil
        lock.lock(); defer { lock.unlock() }
        if ok {
            if readyAt == nil { readyAt = Date(); log("whisper-server ready") }
            return true
        }
        if let startedAt, Date().timeIntervalSince(startedAt) > 60 {
            log("whisper-server not ready after 60s; stopping it")
            process?.terminate()
            process = nil
        }
        return false
    }

    /// A server left behind by a previous app instance (killed, not quit) still
    /// holds the port and a copy of the model in memory.
    private static func killOrphan() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
           String(cString: buffer).hasSuffix("/whisper-server") {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    // MARK: - HTTP

    private struct VerboseJSON: Decodable {
        struct Segment: Decodable { let start: Double; let end: Double; let text: String }
        let segments: [Segment]
    }

    private func post(chunk: URL) throws -> [TranscriptSegment] {
        let audio = try Data(contentsOf: chunk)
        let boundary = "clawgate-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "verbose_json")
        field("temperature", "0.0")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120
        guard let data = Self.send(request, timeout: 125) else {
            throw AmbientTranscriber.TranscribeError.launchFailed("whisper-server did not answer")
        }
        do {
            let decoded = try JSONDecoder().decode(VerboseJSON.self, from: data)
            return decoded.segments.map {
                TranscriptSegment(startSeconds: $0.start, endSeconds: $0.end,
                                  text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }.filter { !$0.text.isEmpty }
        } catch {
            throw AmbientTranscriber.TranscribeError.decodeFailed("whisper-server: \(error)")
        }
    }

    /// Synchronous request for the transcription queue, which is already off
    /// the main thread and processes one chunk at a time.
    private static func send(_ request: URLRequest, timeout: TimeInterval) -> Data? {
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) || request.httpMethod != "POST" {
                result = data ?? Data()
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return nil
        }
        return result
    }
}
