import Foundation
import AVFoundation

/// Orchestrates the Ambient Context Stream on the client: microphone capture
/// (rolling WAV chunks) plus whisper.cpp transcription into per-session
/// transcripts. Capture and streaming are independent states:
///   - capture  = the mic is recording rolling chunks (privacy-controlled)
///   - streaming = ready chunks are transcribed into text
/// Delivery to OpenClaw rides AmbientIngestProducer (ambient.ingest RPC per
/// the oc-general ambient-context contract); it starts/stops with streaming.
final class AmbientController {
    struct Status: Codable {
        var role: String
        var available: Bool
        var captureState: String
        var streaming: Bool
        var micAuthorization: String
        var whisperAvailable: Bool
        var diarizerAvailable: Bool
        var sessionID: String?
        var segmentsTotal: Int
        var segmentsSkipped: Int
        var pendingChunks: Int
        var lastText: String?
        var lastError: String?
        var ingestSent: Int
        var ingestLastError: String?
        // Capture liveness (truthful health, independent of captureState which is
        // only the intended state and lies when the engine silently wedges).
        var captureLiveness: String       // live | stale | wedged | unknown
        var secondsSinceLastTap: Int      // -1 when not capturing / no tap yet
        var secondsSinceLastChunk: Int    // -1 when no chunk surfaced yet
        var chunksSurfaced: Int           // cumulative chunks finalized (incl. silence)
        var recoveryCount: Int
        var lastRecoveryReason: String?
    }

    private let configStore: ConfigStore
    private let log: (String) -> Void
    private let capture: AmbientCaptureManager
    private let transcriber: AmbientTranscriber
    private let diarizer: AmbientDiarizer

    private let state = DispatchQueue(label: "ai.clawgate.ambient.state")
    private let work = DispatchQueue(label: "ai.clawgate.ambient.transcribe")

    private var streaming = false
    private var sessionID: String?
    private var segmentsTotal = 0
    private var skippedTotal = 0
    private var pendingChunks = 0
    private var lastText: String?
    private var lastError: String?
    /// Recently kept segment texts, for cross-chunk rolling-duplicate filtering
    /// (the 3s capture overlap re-transcribes boundary speech).
    private var recentKeptTexts: [String] = []
    private var ingestSent = 0
    private var ingestLastError: String?

    /// Gateway delivery (ambient.ingest). Starts/stops with the stream; send
    /// failures never disturb capture/transcription (log + retry next window).
    private lazy var ingest = AmbientIngestProducer(
        log: log,
        onUpdate: { [weak self] update in
            guard let self else { return }
            self.state.async {
                self.ingestSent = update.sent
                self.ingestLastError = update.lastError
            }
        }
    )

    /// In-app self-heal: detects a silently-wedged capture and hard-recovers it.
    /// Runs only while streaming.
    private lazy var healthMonitor = AmbientHealthMonitor(controller: self, log: log)

    init(configStore: ConfigStore, log: @escaping (String) -> Void = { _ in }) {
        self.configStore = configStore
        self.log = log
        self.capture = AmbientCaptureManager(chunkSeconds: 30, overlapSeconds: 3, log: log)
        self.transcriber = AmbientTranscriber()
        self.diarizer = AmbientDiarizer(log: log)
        self.capture.onChunkReady = { [weak self] url, rms, startedAt in
            self?.handleChunk(url, rms: rms, startedAt: startedAt)
        }
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
                        self.skippedTotal = 0
                        self.recentKeptTexts = []
                        AmbientStorage.ensureDir(self.transcriptDir())
                        self.writeSessionMetadata()
                    }
                    self.streaming = true
                    self.setWasStreaming(true)
                    self.lastError = nil
                    if let sid = self.sessionID {
                        Task { await self.ingest.start(sessionID: sid) }
                    }
                    self.healthMonitor.start()
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
            self.setWasStreaming(false)
            self.healthMonitor.stop()
            Task { await self.ingest.stop() }
            self.log("ambient stream stopped (capture continues=\(self.capture.state == .capturing))")
        }
    }

    /// Hard-stop the microphone (privacy control).
    func pauseCapture() {
        state.async {
            self.streaming = false
            self.setWasStreaming(false)
            self.healthMonitor.stop()
            Task { await self.ingest.stop() }
            self.capture.stop()
        }
    }

    /// Hard-recover a wedged capture in-process (in-app monitor trigger,
    /// /v1/ambient/capture/recover, or the external watchdog backstop).
    func recover(reason: String) {
        state.sync { self.capture.hardRecover(reason: reason) }
    }

    /// TEST ONLY: simulate a capture wedge (engine torn down, captureState left
    /// "capturing") so the detect→recover loop can be verified on demand.
    func simulateWedge() {
        state.sync { self.capture.simulateWedge() }
    }

    // MARK: - Auto-resume across restarts

    /// Persisted intent: was the stream running when the process last lived? A
    /// crash / deploy restart leaves this true so the app resumes itself on
    /// launch; a clean user stop/pause clears it so we never auto-resume after an
    /// intentional stop. This kills the flaky "restart → manual curl restore"
    /// race that left recording silently off for 80min on 2026-06-21.
    private static let wasStreamingKey = "clawgate.ambient.wasStreaming"
    private func setWasStreaming(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.wasStreamingKey)
    }

    /// Called once at app startup: if the stream was on before this launch and
    /// the mic is usable, resume recording automatically.
    func resumeIfWasStreaming() {
        guard isAvailable, UserDefaults.standard.bool(forKey: Self.wasStreamingKey) else { return }
        log("ambient auto-resume: stream was on before launch, restarting")
        startStream { [weak self] result in
            switch result {
            case .success: self?.log("ambient auto-resume ok")
            case .failure(let e): self?.log("ambient auto-resume failed: \(e)")
            }
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
            let capturing = capture.state == .capturing
            let live = capture.livenessSnapshot()
            let now = Date()
            // Liveness is meaningful only while capturing AND streaming (a paused
            // or idle capture is intentionally quiet, not wedged).
            let sinceTap = (capturing && streaming)
                ? live.lastTapAt.map { Int(now.timeIntervalSince($0)) } ?? -1
                : -1
            let sinceChunk = live.lastChunkReadyAt.map { Int(now.timeIntervalSince($0)) } ?? -1
            let liveness = (capturing && streaming)
                ? AmbientCaptureManager.classifyLiveness(capturing: true, secondsSinceLastTap: sinceTap)
                : "unknown"
            return Status(
                role: configStore.load().runtimeRole.rawValue,
                available: isAvailable,
                captureState: capture.state.rawValue,
                streaming: streaming,
                micAuthorization: Self.authString(AmbientCaptureManager.micAuthorizationStatus()),
                whisperAvailable: transcriber.isAvailable,
                diarizerAvailable: diarizer.isAvailable,
                sessionID: sessionID,
                segmentsTotal: segmentsTotal,
                segmentsSkipped: skippedTotal,
                pendingChunks: pendingChunks,
                lastText: lastText,
                lastError: lastError,
                ingestSent: ingestSent,
                ingestLastError: ingestLastError,
                captureLiveness: liveness,
                secondsSinceLastTap: sinceTap,
                secondsSinceLastChunk: sinceChunk,
                chunksSurfaced: live.chunksSurfaced,
                recoveryCount: live.recoveryCount,
                lastRecoveryReason: live.lastRecoveryReason
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

    private func handleChunk(_ url: URL, rms: Float, startedAt: Date) {
        work.async { [weak self] in
            guard let self else { return }
            let shouldRun = self.state.sync { self.streaming }
            guard shouldRun else { return }
            self.state.sync { self.pendingChunks += 1 }
            defer { self.state.sync { self.pendingChunks = max(0, self.pendingChunks - 1) } }
            do {
                // Energy gate: whisper hallucinates ("Thank you." etc.) on silence,
                // which would pollute always-on ambient context. Skip near-silent
                // chunks before transcription. RMS is measured during capture
                // (see AmbientCaptureManager) — re-reading the file here raced
                // the writer's header flush and silently disabled the gate.
                if rms < Self.silenceFloorRMS {
                    self.log(String(format: "ambient chunk gated rms=%.4f < %.4f (silent)", rms, Self.silenceFloorRMS))
                    self.appendSkipped([SkippedSegment(
                        reason: "low_confidence_no_speech",
                        segment: TranscriptSegment(startSeconds: 0, endSeconds: 0,
                                                   text: String(format: "(gated silent chunk rms=%.4f)", rms)))])
                    self.state.sync { self.skippedTotal += 1 }
                    return
                }
                let result = try self.transcriber.transcribe(chunk: url)
                // Speaker labels (self/other) — fail-soft: nil turns leave
                // segments unlabeled, transcription is never blocked.
                let turns = result.kept.isEmpty ? nil : self.diarizer.diarize(chunk: url)
                let labeled = turns.map { AmbientDiarizer.label(segments: result.kept, with: $0) }
                    ?? result.kept
                // Stamp absolute utterance time: chunk start + in-chunk offset.
                let stamped = labeled.map { seg -> TranscriptSegment in
                    var s = seg
                    s.capturedAt = startedAt.timeIntervalSince1970 + seg.startSeconds
                    return s
                }
                var kept: [TranscriptSegment] = []
                var rollingSkipped: [SkippedSegment] = []
                self.state.sync {
                    for seg in stamped {
                        if self.recentKeptTexts.contains(seg.text) {
                            rollingSkipped.append(SkippedSegment(reason: "rolling_duplicate", segment: seg))
                        } else {
                            kept.append(seg)
                            self.recentKeptTexts.append(seg.text)
                        }
                    }
                    if self.recentKeptTexts.count > 40 {
                        self.recentKeptTexts.removeFirst(self.recentKeptTexts.count - 40)
                    }
                }
                let allSkipped = result.skipped + rollingSkipped
                if !kept.isEmpty {
                    self.appendTranscripts(kept)
                    let toSend = kept
                    Task { await self.ingest.add(toSend) }
                }
                if !allSkipped.isEmpty { self.appendSkipped(allSkipped) }
                self.state.sync {
                    self.segmentsTotal += kept.count
                    self.skippedTotal += allSkipped.count
                    if let last = kept.last { self.lastText = last.text }
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

    /// Record the active STT preset/model/thresholds for the session so later
    /// transcript-quality problems can be debugged (docs/ambient-stt-quality.md).
    private func writeSessionMetadata() {
        guard let sid = sessionID else { return }
        struct Meta: Codable {
            let preset: AmbientPreset
            let chunkSeconds: Int
            let promptUsed: Bool
        }
        let meta = Meta(
            preset: transcriber.preset,
            chunkSeconds: capture.chunkSeconds,
            promptUsed: !transcriber.prompt.isEmpty
        )
        let url = AmbientStorage.sessionDir(sid).appendingPathComponent("preset.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(meta) { try? data.write(to: url) }
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

    /// Record filtered-out segments with their reason for later quality audit.
    private func appendSkipped(_ skipped: [SkippedSegment]) {
        let url = transcriptDir().appendingPathComponent("skipped.jsonl")
        let encoder = JSONEncoder()
        var lines = ""
        for s in skipped {
            if let data = try? encoder.encode(s), let line = String(data: data, encoding: .utf8) {
                lines += line + "\n"
            }
        }
        append(lines, to: url)
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

    /// RMS below which a chunk is treated as silence and not transcribed.
    /// Calibrated 2026-06-09 against 61 real chunks: whisper hallucinations
    /// ("Thank you." / "ご視聴ありがとうございました") clustered in the 0.005–0.015
    /// near-silence band (noise floor, peak < 0.5), while genuine speech sat at
    /// rms ≥ 0.017 with peak ≈ 1.0. 0.005 let the whole hallucination band through.
    /// The level itself is measured during capture (AmbientCaptureManager) —
    /// the old approach of reading the level back from the file raced the
    /// header flush, returned nil, and fail-opened the gate on every chunk.
    private static let silenceFloorRMS: Float = 0.015

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
