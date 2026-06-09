import Foundation
import AVFoundation

/// Orchestrates the Ambient Context Stream on the client: microphone capture
/// (rolling WAV chunks) plus whisper.cpp transcription into per-session
/// transcripts. Capture and streaming are independent states:
///   - capture  = the mic is recording rolling chunks (privacy-controlled)
///   - streaming = ready chunks are transcribed into text
/// Delivery to OpenClaw is intentionally out of scope here (contract-first,
/// owned by the oc-general lane).
final class AmbientController {
    struct Status: Codable {
        var role: String
        var available: Bool
        var captureState: String
        var streaming: Bool
        var micAuthorization: String
        var whisperAvailable: Bool
        var sessionID: String?
        var segmentsTotal: Int
        var pendingChunks: Int
        var lastText: String?
        var lastError: String?
    }

    private let configStore: ConfigStore
    private let log: (String) -> Void
    private let capture: AmbientCaptureManager
    private let transcriber: AmbientTranscriber

    private let state = DispatchQueue(label: "ai.clawgate.ambient.state")
    private let work = DispatchQueue(label: "ai.clawgate.ambient.transcribe")

    private var streaming = false
    private var sessionID: String?
    private var segmentsTotal = 0
    private var pendingChunks = 0
    private var lastText: String?
    private var lastError: String?

    init(configStore: ConfigStore, log: @escaping (String) -> Void = { _ in }) {
        self.configStore = configStore
        self.log = log
        self.capture = AmbientCaptureManager(chunkSeconds: 60, log: log)
        self.transcriber = AmbientTranscriber()
        self.capture.onChunkReady = { [weak self] url in self?.handleChunk(url) }
    }

    /// The feature exists only on the client (host that points at a remote Gateway).
    var isAvailable: Bool { configStore.load().isClientRole }

    // MARK: - Controls

    enum ControlError: Error, CustomStringConvertible {
        case clientOnly
        case micDenied
        case captureFailed(String)
        var description: String {
            switch self {
            case .clientOnly: return "Ambient Context Stream is only available in client mode."
            case .micDenied: return "Microphone access was denied."
            case .captureFailed(let m): return "capture failed: \(m)"
            }
        }
    }

    /// Start the Context Stream: ensure capture is running and begin transcribing.
    func startStream(completion: @escaping (Result<Void, ControlError>) -> Void) {
        guard isAvailable else { completion(.failure(.clientOnly)); return }
        AmbientCaptureManager.requestMicAccess { [weak self] granted in
            guard let self else { return }
            guard granted else { completion(.failure(.micDenied)); return }
            self.state.async {
                do {
                    if self.capture.state != .capturing {
                        if self.capture.state == .paused {
                            try self.capture.resume()
                        } else {
                            try self.capture.start()
                        }
                    }
                    if self.sessionID == nil {
                        self.sessionID = Self.newSessionID()
                        self.segmentsTotal = 0
                        AmbientStorage.ensureDir(self.transcriptDir())
                    }
                    self.streaming = true
                    self.lastError = nil
                    self.log("ambient stream started session=\(self.sessionID ?? "?")")
                    completion(.success(()))
                } catch {
                    completion(.failure(.captureFailed("\(error)")))
                }
            }
        }
    }

    /// Stop transcribing/delivering. Capture may keep running.
    func stopStream() {
        state.async {
            self.streaming = false
            self.log("ambient stream stopped (capture continues=\(self.capture.state == .capturing))")
        }
    }

    /// Hard-stop the microphone (privacy control).
    func pauseCapture() {
        state.async {
            self.streaming = false
            self.capture.stop()
        }
    }

    func resumeCapture(completion: @escaping (Result<Void, ControlError>) -> Void) {
        guard isAvailable else { completion(.failure(.clientOnly)); return }
        AmbientCaptureManager.requestMicAccess { [weak self] granted in
            guard let self else { return }
            guard granted else { completion(.failure(.micDenied)); return }
            self.state.async {
                do {
                    if self.capture.state == .idle { try self.capture.start() }
                    else if self.capture.state == .paused { try self.capture.resume() }
                    completion(.success(()))
                } catch {
                    completion(.failure(.captureFailed("\(error)")))
                }
            }
        }
    }

    // MARK: - Status

    func snapshot() -> Status {
        state.sync {
            Status(
                role: configStore.load().runtimeRole.rawValue,
                available: isAvailable,
                captureState: capture.state.rawValue,
                streaming: streaming,
                micAuthorization: Self.authString(AmbientCaptureManager.micAuthorizationStatus()),
                whisperAvailable: transcriber.isAvailable,
                sessionID: sessionID,
                segmentsTotal: segmentsTotal,
                pendingChunks: pendingChunks,
                lastText: lastText,
                lastError: lastError
            )
        }
    }

    /// Read a session's cleaned transcript text.
    func transcriptText(sessionID: String) -> String? {
        let url = AmbientStorage.sessionDir(sessionID)
            .appendingPathComponent("transcripts/cleaned.md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func sessionIDs() -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            at: AmbientStorage.sessionsRoot,
            includingPropertiesForKeys: nil
        ))?.map { $0.lastPathComponent }.sorted() ?? []
    }

    // MARK: - Chunk handling

    private func handleChunk(_ url: URL) {
        work.async { [weak self] in
            guard let self else { return }
            let shouldRun = self.state.sync { self.streaming }
            guard shouldRun else { return }
            self.state.sync { self.pendingChunks += 1 }
            defer { self.state.sync { self.pendingChunks = max(0, self.pendingChunks - 1) } }
            do {
                let segments = try self.transcriber.transcribe(chunk: url)
                guard !segments.isEmpty else { return }
                self.appendTranscripts(segments)
                self.state.sync {
                    self.segmentsTotal += segments.count
                    self.lastText = segments.last?.text
                }
            } catch {
                self.state.sync { self.lastError = "\(error)" }
                self.log("ambient transcription error: \(error)")
            }
        }
    }

    private func transcriptDir() -> URL {
        AmbientStorage.sessionDir(sessionID ?? "unknown")
            .appendingPathComponent("transcripts", isDirectory: true)
    }

    private func appendTranscripts(_ segments: [TranscriptSegment]) {
        let dir = transcriptDir()
        AmbientStorage.ensureDir(dir)
        let rawURL = dir.appendingPathComponent("raw.jsonl")
        let mdURL = dir.appendingPathComponent("cleaned.md")
        let encoder = JSONEncoder()
        var rawLines = ""
        var mdLines = ""
        for seg in segments {
            if let data = try? encoder.encode(seg), let line = String(data: data, encoding: .utf8) {
                rawLines += line + "\n"
            }
            mdLines += seg.text + "\n"
        }
        append(rawLines, to: rawURL)
        append(mdLines, to: mdURL)
    }

    private func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Helpers

    private static func newSessionID() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        fmt.timeZone = TimeZone(identifier: "UTC")
        let stamp = fmt.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "ctx-\(stamp)"
    }

    private static func authString(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}
