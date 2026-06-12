import Foundation
import CryptoKit
import NaturalLanguage

// MARK: - ambient.ingest wire types (contract: oc-general ambient-context.md 2026.6.9-1)

struct AmbientSourceWindow: Encodable {
    let start: Int64  // unix-ms
    let end: Int64
}

struct AmbientSourceRef: Encodable {
    let source: String
    let sourceWindow: AmbientSourceWindow
    let confidence: Double
}

/// L1 ambient state snapshot — latched rolling state, no lifecycle.
struct AmbientStateL1: Encodable {
    let updatedAt: Int64
    let staleAfter: Int64
    let sourceWindow: AmbientSourceWindow
    let confidence: Double
    let summary: String
    let placeHint: String?
    let topicHint: String?
    let activityHint: String?
    let peopleHintRedacted: [String]
    let privacyFlags: [String]
    let sources: [AmbientSourceRef]
}

/// L2 salient event (contract "L2 Salient Event Schema").
struct AmbientSalientEvent: Encodable {
    let source: String
    let sourceSeq: Int
    let sourceEventId: String
    let eventType: String
    let normalizedSubject: String
    let normalizedDateBucket: String?
    let dedupKey: String
    let summary: String
    let confidence: Double
    let sourceWindow: AmbientSourceWindow
    let privacyFlags: [String]
}

struct AmbientIngestParams: Encodable {
    let source: String
    let device: String
    let captureMode: String
    let latencyClass: String
    let sourceWindow: AmbientSourceWindow
    let sourceSeq: Int
    let sourceIds: [String]
    let confidence: Double
    let state: AmbientStateL1
    let events: [AmbientSalientEvent]?
}

// MARK: - Producer

/// Sends L1 ambient state (+ extracted L2 events) to the OpenClaw Gateway via
/// the `ambient.ingest` RPC.
///
/// Content policy (御大 ruling 2026-06-11): the summary carries the window's
/// actual transcript text — this is the owner's own assistant receiving the
/// owner's own room audio, so no self-imposed redaction. The earlier
/// template-only summary ("conversation observed, recurring terms: …") is
/// kept only as topicHint/activityHint metadata. Audio itself never leaves
/// the device; rolling WAVs stay in local 6h retention.
///
/// Throttle (contract "Throttle"): one 60s window; a window with no new kept
/// segments sends nothing ("no change → no send"). Failed sends keep the
/// window and retry on the next tick — no hammering.
actor AmbientIngestProducer {
    struct Update {
        let sent: Int
        let lastError: String?
    }

    private let log: (String) -> Void
    private let onUpdate: (Update) -> Void

    private var client: OpenClawWSClient?
    private var drainTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var connected = false
    private var running = false
    private var sessionID = ""

    /// One transcript line flowing into the 60s window — text plus the speaker
    /// label and capture time needed for the dialogue-format summary.
    struct Line {
        let text: String
        let speaker: String?   // "self" | "other" | nil (no diarization)
        let capturedAt: Date?
    }

    private struct WindowSegment {
        let line: Line
        let addedAt: Date
    }
    private var window: [WindowSegment] = []
    private var sentTotal = 0
    private var lastError: String?
    /// Layer-1 local suppression: dedupKeys already sent this run. The Gateway
    /// still applies layer-3 semantic dedup; this just avoids re-sending.
    private var sentDedupKeys = Set<String>()

    private static let flushIntervalNs: UInt64 = 60_000_000_000  // 60s window
    private static let staleAfterSeconds: TimeInterval = 180     // updatedAt + 3min
    private static let windowCap = 120                            // bound retry backlog

    init(log: @escaping (String) -> Void = { _ in },
         onUpdate: @escaping (Update) -> Void = { _ in }) {
        self.log = log
        self.onUpdate = onUpdate
    }

    // MARK: - Lifecycle

    func start(sessionID: String) {
        guard !running else { return }
        running = true
        self.sessionID = sessionID
        flushTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.flushIntervalNs)
                guard let self else { return }
                guard await self.isRunning() else { return }
                await self.flush()
            }
        }
        log("ambient ingest producer started session=\(sessionID)")
    }

    func stop() async {
        guard running else { return }
        await flush()  // best-effort final send of the remaining window
        running = false
        flushTask?.cancel(); flushTask = nil
        drainTask?.cancel(); drainTask = nil
        if let c = client { await c.disconnect() }
        client = nil
        connected = false
        sessionID = ""
        log("ambient ingest producer stopped")
    }

    func add(_ segments: [TranscriptSegment]) {
        guard running, !segments.isEmpty else { return }
        let now = Date()
        window.append(contentsOf: segments.map {
            WindowSegment(
                line: Line(text: $0.text,
                           speaker: $0.speaker,
                           capturedAt: $0.capturedAt.map { Date(timeIntervalSince1970: $0) }),
                addedAt: now
            )
        })
        if window.count > Self.windowCap {
            window.removeFirst(window.count - Self.windowCap)
        }
    }

    private func isRunning() -> Bool { running }
    private func setConnected(_ v: Bool) { connected = v }

    // MARK: - Flush

    private func flush() async {
        guard running, !window.isEmpty else { return }  // no new speech → no send
        let segments = window
        let lines = segments.map { $0.line }
        let texts = lines.map { $0.text }
        let windowStart = segments.first?.addedAt ?? Date()
        let windowEnd = segments.last?.addedAt ?? Date()

        // L2: extract salient events, suppress already-sent keys (layer 1).
        let drafts = AmbientSalientExtractor.extract(from: texts)
            .filter { !sentDedupKeys.contains($0.dedupKey) }
        let sw = AmbientSourceWindow(
            start: Int64(windowStart.timeIntervalSince1970 * 1000),
            end: Int64(windowEnd.timeIntervalSince1970 * 1000)
        )
        let events: [AmbientSalientEvent] = drafts.map { d in
            let seq = Self.nextSourceSeq()
            return AmbientSalientEvent(
                source: "clawgate_ambient",
                sourceSeq: seq,
                sourceEventId: "\(sessionID)-ev\(seq)",
                eventType: d.eventType,
                normalizedSubject: d.normalizedSubject,
                normalizedDateBucket: d.normalizedDateBucket,
                dedupKey: d.dedupKey,
                summary: d.summary,
                confidence: d.confidence,
                sourceWindow: sw,
                privacyFlags: []
            )
        }

        let params = Self.buildParams(
            lines: lines,
            windowStart: windowStart,
            windowEnd: windowEnd,
            sessionID: sessionID,
            sourceSeq: Self.nextSourceSeq(),
            now: Date(),
            events: events.isEmpty ? nil : events
        )
        do {
            try await ensureConnected()
            guard let c = client else { throw OpenClawError.connectionFailed("no client") }
            let payload = try await c.request(method: "ambient.ingest", params: params)
            let accepted = payload?.stateAccepted ?? false
            sentTotal += 1
            lastError = nil
            window.removeAll()
            // Everything sent successfully is locally suppressed (layer 1) —
            // strictly stronger than suppressing only dedup:"duplicate"
            // receipts. Receipts are still surfaced for observability.
            for d in drafts { sentDedupKeys.insert(d.dedupKey) }
            let receipts = payload?.events ?? []
            let dupCount = receipts.filter { $0.dedup == "duplicate" }.count
            log("ambient ingest ok seq=\(params.sourceSeq) accepted=\(accepted) segs=\(segments.count) events=\(events.count) receipts=\(receipts.count) dup=\(dupCount)")
            onUpdate(Update(sent: sentTotal, lastError: nil))
        } catch {
            // Keep the window; the next 60s tick retries once. No hammering.
            lastError = "\(error)"
            log("ambient ingest failed (retry next window): \(error)")
            onUpdate(Update(sent: sentTotal, lastError: "\(error)"))
        }
    }

    // MARK: - Connection (same recipe as PetModel: local openclaw.json token + AppConfig host)

    private func ensureConnected() async throws {
        if connected, client != nil { return }
        drainTask?.cancel(); drainTask = nil
        if let c = client { await c.disconnect() }
        client = nil
        connected = false

        guard let gw = readOpenClawGatewayConfig() else {
            throw OpenClawError.connectionFailed("no gateway config (~/.openclaw/openclaw.json)")
        }
        let cfg = ConfigStore().load()
        let host = cfg.openclawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = cfg.openclawPort
        guard !host.isEmpty, (1...65535).contains(port),
              let url = URL(string: "ws://\(host):\(port)/") else {
            throw OpenClawError.connectionFailed("invalid gateway host/port")
        }

        let c = OpenClawWSClient()
        let stream = try await c.connect(url: url, token: gw.token)
        client = c
        drainTask = Task { [weak self] in
            for await event in stream {
                switch event {
                case .connected:
                    await self?.setConnected(true)
                case .disconnected:
                    await self?.setConnected(false)
                default:
                    break
                }
            }
            await self?.setConnected(false)
        }

        // connect() already waited for HTTP /ready; the WS handshake itself is
        // bounded by the client's internal 10s timeout, which tears down and
        // flips us back to disconnected. Poll with a hard deadline on top.
        let deadline = Date().addingTimeInterval(20)
        while !connected {
            if Date() > deadline { throw OpenClawError.timeout }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        log("ambient ingest connected to \(host):\(port)")
    }

    // MARK: - L1 construction (pure, testable)

    static func buildParams(lines: [Line],
                            windowStart: Date,
                            windowEnd: Date,
                            sessionID: String,
                            sourceSeq: Int,
                            now: Date,
                            events: [AmbientSalientEvent]? = nil,
                            timeZone: TimeZone = .current) -> AmbientIngestParams {
        let segmentTexts = lines.map { $0.text }
        let sw = AmbientSourceWindow(
            start: Int64(windowStart.timeIntervalSince1970 * 1000),
            end: Int64(windowEnd.timeIntervalSince1970 * 1000)
        )
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let keywords = recurringKeywords(in: segmentTexts)

        // The summary carries the actual window transcript. This is the
        // owner's own assistant receiving the owner's own room audio — 御大
        // ruling 2026-06-11: deliver the real text, no self-imposed redaction
        // (the earlier template-only summary made the feature useless, like a
        // minutes app that refuses to share the minutes). Capped to the most
        // recent tail to stay clear of payload limits. With diarization the
        // text becomes dialogue-formatted: "[HH:mm] ご主人様: …" / "相手: …";
        // unlabeled lines render without a speaker head (legacy behavior).
        let summary = Self.dialogueSummary(lines, timeZone: timeZone)

        let activity: String
        switch segmentTexts.count {
        case 6...: activity = "active conversation"
        case 2...5: activity = "intermittent conversation"
        default: activity = "sparse speech"
        }

        // Confidence scales with how much corroborating speech the window has.
        let confidence = min(0.85, 0.35 + 0.05 * Double(segmentTexts.count))

        let state = AmbientStateL1(
            updatedAt: nowMs,
            staleAfter: nowMs + Int64(staleAfterSeconds * 1000),
            sourceWindow: sw,
            confidence: confidence,
            summary: summary,
            placeHint: nil,
            topicHint: keywords.isEmpty ? nil : keywords.joined(separator: ", "),
            activityHint: activity,
            peopleHintRedacted: presentSpeakers(in: lines),
            privacyFlags: [],
            sources: [AmbientSourceRef(source: "clawgate_ambient", sourceWindow: sw, confidence: confidence)]
        )
        return AmbientIngestParams(
            source: "clawgate_ambient",
            device: opaqueDeviceID(),
            captureMode: "ambient",
            latencyClass: "near-realtime",
            sourceWindow: sw,
            sourceSeq: sourceSeq,
            sourceIds: [sessionID],
            confidence: confidence,
            state: state,
            events: events
        )
    }

    /// The window's transcript text, joined chronologically and capped to the
    /// most recent `maxChars` so a dense window can't trip PAYLOAD_TOO_LARGE.
    static func windowTranscript(_ segmentTexts: [String], maxChars: Int = 1500) -> String {
        let joined = segmentTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard joined.count > maxChars else { return joined }
        return "…" + String(joined.suffix(maxChars))
    }

    /// Dialogue-formatted window transcript: consecutive same-speaker lines
    /// merge into one utterance headed by "[HH:mm] ご主人様: " / "[HH:mm] 相手: "
    /// (no speaker head when unlabeled). Same 1500-char recent-tail cap as
    /// windowTranscript. With no speakers and no timestamps this degrades to
    /// the plain joined transcript.
    static func dialogueSummary(_ lines: [Line],
                                maxChars: Int = 1500,
                                timeZone: TimeZone = .current) -> String {
        struct Utterance {
            let speaker: String?
            let time: Date?
            var texts: [String]
        }
        var utterances: [Utterance] = []
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !utterances.isEmpty, utterances[utterances.count - 1].speaker == line.speaker {
                utterances[utterances.count - 1].texts.append(trimmed)
            } else {
                utterances.append(Utterance(speaker: line.speaker, time: line.capturedAt, texts: [trimmed]))
            }
        }
        guard !utterances.isEmpty else { return "" }

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.timeZone = timeZone

        let rendered = utterances.map { u -> String in
            var head = ""
            if let t = u.time { head += "[" + fmt.string(from: t) + "] " }
            switch u.speaker {
            case "self": head += "ご主人様: "
            case "other": head += "相手: "
            default: break
            }
            return head + u.texts.joined(separator: " ")
        }.joined(separator: "\n")

        guard rendered.count > maxChars else { return rendered }
        return "…" + String(rendered.suffix(maxChars))
    }

    /// Presence hint for L1: which diarized parties spoke in this window.
    static func presentSpeakers(in lines: [Line]) -> [String] {
        var people: [String] = []
        if lines.contains(where: { $0.speaker == "self" }) { people.append("ご主人様") }
        if lines.contains(where: { $0.speaker == "other" }) { people.append("相手") }
        return people
    }

    /// Nouns that recur (>= 2 occurrences) across the window (via the shared
    /// AmbientSalientExtractor.contentNouns) — a compact topicHint alongside
    /// the verbatim summary.
    static func recurringKeywords(in segmentTexts: [String], limit: Int = 3) -> [String] {
        let joined = segmentTexts.joined(separator: "\n")
        guard !joined.isEmpty else { return [] }
        var freq: [String: Int] = [:]
        for w in AmbientSalientExtractor.contentNouns(in: joined) {
            freq[w, default: 0] += 1
        }
        return freq.filter { $0.value >= 2 }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit)
            .map { $0.key }
    }

    /// Opaque device id: hash of the WS device identity (itself a key hash —
    /// no hostname anywhere), namespaced for ambient.
    static func opaqueDeviceID() -> String {
        let base: String
        if let id = (try? OpenClawDeviceIdentity.loadOrCreate())?.deviceId {
            base = id
        } else {
            let key = "clawgate.ambient.fallbackDeviceID"
            if let saved = UserDefaults.standard.string(forKey: key) {
                base = saved
            } else {
                let fresh = UUID().uuidString
                UserDefaults.standard.set(fresh, forKey: key)
                base = fresh
            }
        }
        let hex = SHA256.hash(data: Data(base.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "cg-" + String(hex.prefix(16))
    }

    /// Per-source monotonic sequence, persisted across restarts.
    static func nextSourceSeq() -> Int {
        let key = "clawgate.ambient.sourceSeq"
        let next = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(next, forKey: key)
        return next
    }
}
