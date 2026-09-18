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
        // Input device truth: what was asked for versus what the engine is on.
        // They have been observed to differ, silently, with AirPods connected.
        var requestedInputDeviceUID: String?
        var actualInputDeviceUID: String?
        var actualInputDeviceName: String?
        var inputDeviceDrifted: Bool
        var suppressedAutoRecovers: Int
        var lastSuppressedRecoveryReason: String?
        /// Seconds since the live session was bound to the actual device --
        /// the age of the binding, not of a repeated observation. An
        /// AVCaptureDeviceInput cannot change device underneath the session, so
        /// a large value with the same generation is a long, healthy session.
        /// Do not read it as staleness; liveness is `captureLiveness`.
        /// Nil until a session has started.
        var actualInputObservedAgeSeconds: Int?
        // Backend lifecycle, cached and never read from Core Audio here. The
        // process watchdog restarts the app on `timedOut`, or on `starting`
        // that has aged past what a start can take.
        var backendPhase: String
        var backendPhaseAgeSeconds: Int
        var backendGeneration: Int
        /// Typed safety inhibit, separate from the user's intent to stream.
        /// Present means: do not open the microphone on launch until a person
        /// starts it again.
        var autoResumeBlockedReason: String?
        /// Google Meet second stream (Chrome output = the remote party).
        var meetingActive: Bool = false
        var systemTapState: String = "idle"
        var systemTapError: String? = nil
        var systemChunksSurfaced: Int = 0
        var lastSystemChunkAgeSeconds: Int = -1   // -1 when none yet
        var systemTapDiagnostics: String? = nil
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

    /// Google Meet: while the Chrome extension reports a call, Chrome's output
    /// (the remote party) is recorded as a second stream. The report is a
    /// heartbeat; silence past `meetingHeartbeatTTL` ends the call, so a closed
    /// tab or a stopped extension never leaves the tap running.
    private let systemTap: SystemAudioTap
    private var meetingActive = false
    private var meetingLastSeen: Date?
    private var meetingExpiryTimer: DispatchSourceTimer?
    private var recentSystemSegments: [TranscriptSegment] = []
    static let meetingHeartbeatTTL: TimeInterval = 30
    static let echoHoldSeconds = 35

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
        self.systemTap = SystemAudioTap(chunkSeconds: 30, overlapSeconds: 3, log: log)
        self.capture.onChunkReady = { [weak self] chunk in
            self?.handleChunk(chunk)
        }
        self.systemTap.onChunkReady = { [weak self] chunk in
            self?.handleChunk(chunk)
        }
        self.capture.onQuarantine = { [weak self] reason in
            self?.setAutoResumeBlocked(reason: reason)
        }
        // The inhibit is cleared only by audio actually arriving from a session
        // the user started. Clearing on "start accepted" would reopen the
        // microphone on the next launch even when that start never delivered.
        self.capture.onFirstBuffer = { [weak self] _ in
            self?.setAutoResumeBlocked(reason: nil)
        }
        self.capture.setPreferredDevice(uid: configStore.load().ambientMicDeviceUID)
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
                    self.reconcileSystemTapLocked()
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
            // The microphone may stay open after the stream stops. While it does,
            // the monitor stays up so a later input-device drift is still caught;
            // it has nothing to do for a wedge (liveness is unknown when not
            // streaming), so only pauseCapture stops it.
            if self.capture.state != .capturing {
                self.healthMonitor.stop()
            }
            self.reconcileSystemTapLocked()
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
            self.reconcileSystemTapLocked()
            Task { await self.ingest.stop() }
            self.capture.stop()
        }
    }

    // MARK: - Google Meet (second stream)

    /// Heartbeat from the Chrome extension: `inCall` while a Meet call is up.
    func meetingHeartbeat(inCall: Bool) {
        state.async {
            let wasActive = self.meetingActive
            self.meetingActive = inCall
            self.meetingLastSeen = inCall ? Date() : nil
            if wasActive != inCall { self.log("ambient meeting \(inCall ? "started" : "ended")") }
            self.reconcileSystemTapLocked()
        }
    }

    /// Run the Chrome tap exactly when streaming during a call. Called on `state`.
    private func reconcileSystemTapLocked() {
        let want = streaming && meetingActive
        systemTap.setActive(want)
        if meetingActive, meetingExpiryTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: state)
            timer.schedule(deadline: .now() + 10, repeating: 10)
            timer.setEventHandler { [weak self] in self?.expireMeetingIfSilentLocked() }
            timer.resume()
            meetingExpiryTimer = timer
        } else if !meetingActive, let timer = meetingExpiryTimer {
            timer.cancel()
            meetingExpiryTimer = nil
            recentSystemSegments = []
        }
    }

    private func expireMeetingIfSilentLocked() {
        guard meetingActive else { return }
        if let seen = meetingLastSeen, Date().timeIntervalSince(seen) < Self.meetingHeartbeatTTL {
            systemTap.setActive(streaming)   // re-checks Chrome's audio processes
            return
        }
        meetingActive = false
        meetingLastSeen = nil
        log("ambient meeting ended (no heartbeat for \(Int(Self.meetingHeartbeatTTL))s)")
        reconcileSystemTapLocked()
    }

    /// A microphone segment that repeats what Chrome played a moment earlier is
    /// the remote party leaking out of the Mac's speakers, not the owner.
    static func isMeetingEcho(_ mic: TranscriptSegment, against system: [TranscriptSegment],
                              window: Double = 5, threshold: Double = 0.6) -> Bool {
        guard let micAt = mic.capturedAt else { return false }
        let micText = normalizedForEcho(mic.text)
        guard micText.count >= 2 else { return false }
        for seg in system {
            guard let at = seg.capturedAt, abs(at - micAt) <= window else { continue }
            let other = normalizedForEcho(seg.text)
            guard !other.isEmpty else { continue }
            if micText.count >= 4, other.contains(micText) || micText.contains(other) { return true }
            if similarity(micText, other) >= threshold { return true }
        }
        return false
    }

    private static func normalizedForEcho(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 1 - (edit distance / longer length).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// Hard-recover a wedged capture in-process (in-app monitor trigger,
    /// /v1/ambient/capture/recover, or the external watchdog backstop).
    func recover(reason: String) {
        state.sync { self.capture.hardRecover(reason: reason) }
    }

    /// Automatic recovery, subject to the capture manager's shared cooldown.
    /// Returns false when refused. Used by the health monitor; manual and
    /// user-initiated recovery goes through `recover` and is never refused.
    func autoRecover(reason: String) -> Bool {
        state.sync { self.capture.autoRecover(reason: reason) }
    }

    /// TEST ONLY: simulate a capture wedge (engine torn down, captureState left
    /// "capturing") so the detect→recover loop can be verified on demand.
    func simulateWedge() {
        state.sync { self.capture.simulateWedge() }
    }

    func availableMicDevices() -> [MicrophoneDeviceService.MicrophoneDevice] {
        MicrophoneDeviceService.listInputDevices()
    }

    var selectedMicDeviceUID: String? {
        configStore.load().ambientMicDeviceUID
    }

    func selectMicDevice(uid: String?) {
        var cfg = configStore.load()
        cfg.ambientMicDeviceUID = uid
        configStore.save(cfg)
        capture.setPreferredDevice(uid: uid)
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

    /// A safety inhibit, kept apart from `wasStreaming` on purpose. The flag
    /// above is what the user wanted; this is the app refusing to act on it
    /// until a person intervenes, because the last backend never finished and
    /// opening the microphone again on launch would repeat the hang. Cleared
    /// only when a session the person started delivers its first buffer.
    static let autoResumeBlockedReasonKey = "clawgate.ambient.autoResumeBlockedReason"
    private func setAutoResumeBlocked(reason: String?) {
        if let reason {
            UserDefaults.standard.set(reason, forKey: Self.autoResumeBlockedReasonKey)
            log("ambient auto-resume blocked: \(reason)")
        } else {
            UserDefaults.standard.removeObject(forKey: Self.autoResumeBlockedReasonKey)
        }
    }
    private var autoResumeBlockedReason: String? {
        UserDefaults.standard.string(forKey: Self.autoResumeBlockedReasonKey)
    }

    /// Whether launch may resume the microphone. Pure, so the two flags'
    /// precedence is pinned: the inhibit always wins over the intent.
    static func shouldAutoResume(wasStreaming: Bool, blockedReason: String?) -> Bool {
        wasStreaming && (blockedReason ?? "").isEmpty
    }

    /// Called once at app startup: if the stream was on before this launch,
    /// nothing is inhibiting it, and the mic is usable, resume automatically.
    func resumeIfWasStreaming() {
        guard isAvailable else { return }
        let wasStreaming = UserDefaults.standard.bool(forKey: Self.wasStreamingKey)
        let blocked = autoResumeBlockedReason
        guard Self.shouldAutoResume(wasStreaming: wasStreaming, blockedReason: blocked) else {
            if wasStreaming, let blocked { log("ambient auto-resume inhibited: \(blocked)") }
            return
        }
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
                    // Capture can run without a stream; the monitor still has
                    // to watch the input device while the microphone is open.
                    self.healthMonitor.start()
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
            // Cached only. A status call must never wait on Core Audio.
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
                lastRecoveryReason: live.lastRecoveryReason,
                requestedInputDeviceUID: live.requestedInputDeviceUID,
                actualInputDeviceUID: live.actualInputDeviceUID,
                actualInputDeviceName: live.actualInputDeviceName,
                // Judged whenever the microphone is open, streaming or not: the
                // wrong input is wrong audio either way, and with AirPods it
                // degrades the user's output too.
                inputDeviceDrifted: capturing && live.inputDeviceDrifted,
                suppressedAutoRecovers: live.suppressedAutoRecovers,
                lastSuppressedRecoveryReason: live.lastSuppressedRecoveryReason,
                actualInputObservedAgeSeconds: live.actualInputObservedAt.map { Int(now.timeIntervalSince($0)) },
                backendPhase: live.backendPhase.rawValue,
                backendPhaseAgeSeconds: Int(now.timeIntervalSince(live.backendPhaseSince)),
                backendGeneration: live.backendGeneration,
                autoResumeBlockedReason: autoResumeBlockedReason,
                meetingActive: meetingActive,
                systemTapState: systemTap.state.rawValue,
                systemTapError: systemTap.lastError,
                systemChunksSurfaced: systemTap.chunksSurfaced,
                lastSystemChunkAgeSeconds: systemTap.lastChunkAt.map { Int(now.timeIntervalSince($0)) } ?? -1,
                systemTapDiagnostics: systemTap.diagnostics
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

    private func handleChunk(_ chunk: AmbientCaptureManager.CompletedChunk) {
        // On the Mac's own speakers the remote party leaks into the microphone.
        // Hold such mic chunks until the Chrome chunk covering the same period
        // (finalized at most one chunk later) has been transcribed, so the leak
        // can be recognised against it.
        let holdForEcho = chunk.source == .mic
            && state.sync { meetingActive }
            && SystemAudioTap.outputIsBuiltInSpeaker()
        let delay: DispatchTimeInterval = holdForEcho ? .seconds(Self.echoHoldSeconds) : .seconds(0)
        work.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let shouldRun = self.state.sync { self.streaming }
            guard shouldRun else { return }
            self.state.sync { self.pendingChunks += 1 }
            defer { self.state.sync { self.pendingChunks = max(0, self.pendingChunks - 1) } }
            do {
                let rms = chunk.rms
                // Zero-capture gate: skip only chunks with no signal at all
                // (e.g. a muted/disconnected input). Actual speech-vs-silence
                // judgment belongs to Whisper + Silero VAD (see
                // AmbientTranscriber.preset.vad), not a whole-chunk RMS
                // threshold — real conversational audio can measure well
                // below what "sounds loud" in RMS terms (2026-07-15
                // incident: 18 real-speech chunks at rms 0.005803–0.014562
                // were wrongly pre-gated as silence and never transcribed).
                if Self.isZeroCapture(rms: rms) {
                    self.log(String(format: "ambient chunk skipped rms=%.6f (zero_audio)", rms))
                    self.appendSkipped([SkippedSegment(
                        reason: "zero_audio",
                        segment: TranscriptSegment(startSeconds: 0, endSeconds: 0,
                                                   text: String(format: "(zero_audio chunk rms=%.6f)", rms)))])
                    self.state.sync { self.skippedTotal += 1 }
                    return
                }
                let result = try self.transcriber.transcribe(chunk: chunk.url)
                let inMeeting = self.state.sync { self.meetingActive }
                let labeled: [TranscriptSegment]
                if chunk.source == .system {
                    // Chrome never plays the owner back to themself: all of it is the other party.
                    labeled = result.kept.map { var s = $0; s.speaker = "other"; return s }
                } else if inMeeting {
                    // During a call the other party arrives through Chrome, so the
                    // microphone is the owner. The stream decides, not a guess.
                    labeled = result.kept.map { var s = $0; s.speaker = "self"; return s }
                } else {
                    // Speaker labels (self/other) — fail-soft: nil turns leave
                    // segments unlabeled, transcription is never blocked.
                    let turns = result.kept.isEmpty ? nil : self.diarizer.diarize(chunk: chunk.url)
                    labeled = turns.map { AmbientDiarizer.label(segments: result.kept, with: $0) }
                        ?? result.kept
                }
                // Stamp absolute utterance time: chunk start + in-chunk offset.
                let stamped = labeled.map { seg -> TranscriptSegment in
                    var s = seg
                    if let startedAt = chunk.startedAt {
                        s.capturedAt = startedAt.timeIntervalSince1970 + seg.startSeconds
                    }
                    s.stream = chunk.source.rawValue
                    return s
                }
                var kept: [TranscriptSegment] = []
                var rollingSkipped: [SkippedSegment] = []
                self.state.sync {
                    // The two streams hear different people, so a short reply that
                    // both sides say ("はい") must not cancel the other side's.
                    let prefix = chunk.source.rawValue + ":"
                    for seg in stamped {
                        if self.recentKeptTexts.contains(prefix + seg.text) {
                            rollingSkipped.append(SkippedSegment(reason: "rolling_duplicate", segment: seg))
                        } else if holdForEcho,
                                  Self.isMeetingEcho(seg, against: self.recentSystemSegments) {
                            rollingSkipped.append(SkippedSegment(reason: "meeting_echo", segment: seg))
                        } else {
                            kept.append(seg)
                            self.recentKeptTexts.append(prefix + seg.text)
                        }
                    }
                    if self.recentKeptTexts.count > 40 {
                        self.recentKeptTexts.removeFirst(self.recentKeptTexts.count - 40)
                    }
                    if chunk.source == .system {
                        self.recentSystemSegments.append(contentsOf: kept)
                        let horizon = Date().timeIntervalSince1970 - 180
                        self.recentSystemSegments.removeAll { ($0.capturedAt ?? 0) < horizon }
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

    /// RMS at or below this is treated as truly empty capture (no signal
    /// whatsoever — e.g. a muted/disconnected input), not as "quiet speech".
    /// This is deliberately far below any real audio level; genuine speech
    /// and background conversation can both sit well under naive "loudness"
    /// expectations, so speech-vs-silence judgment is delegated entirely to
    /// Whisper + Silero VAD (AmbientTranscriber.preset.vad) rather than a
    /// whole-chunk RMS threshold. The level itself is measured during
    /// capture (AmbientCaptureManager) — re-reading it from the file here
    /// raced the writer's header flush and silently disabled the gate.
    private static let zeroCaptureRMSEpsilon: Float = 1e-6

    static func isZeroCapture(rms: Float) -> Bool {
        rms <= zeroCaptureRMSEpsilon
    }

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
