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

/// Sends privacy-processed L1 ambient state to the OpenClaw Gateway via the
/// `ambient.ingest` RPC (Phase 1: L1 only, no L2 events).
///
/// Privacy invariants (contract "Privacy / Redaction"):
///  - summary is a processed template + recurring noun keywords, never verbatim
///    transcript sentences; raw transcript stays in local 6h-retention storage.
///  - words tagged as personal/place/organization names are excluded from
///    keywords (default redact, fail-closed — Phase 1 sends no names at all).
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

    private struct WindowSegment {
        let text: String
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
        window.append(contentsOf: segments.map { WindowSegment(text: $0.text, addedAt: now) })
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
        let texts = segments.map { $0.text }
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
            segmentTexts: texts,
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
            for d in drafts { sentDedupKeys.insert(d.dedupKey) }
            log("ambient ingest ok seq=\(params.sourceSeq) accepted=\(accepted) segs=\(segments.count) events=\(events.count)")
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

    static func buildParams(segmentTexts: [String],
                            windowStart: Date,
                            windowEnd: Date,
                            sessionID: String,
                            sourceSeq: Int,
                            now: Date,
                            events: [AmbientSalientEvent]? = nil) -> AmbientIngestParams {
        let sw = AmbientSourceWindow(
            start: Int64(windowStart.timeIntervalSince1970 * 1000),
            end: Int64(windowEnd.timeIntervalSince1970 * 1000)
        )
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let keywords = recurringKeywords(in: segmentTexts)
        let minutes = max(windowEnd.timeIntervalSince(windowStart) / 60, 0)
        let span = max(1, Int(minutes.rounded()))

        var summary = "Nearby conversation observed: \(segmentTexts.count) spoken segment(s) over ~\(span) min."
        if !keywords.isEmpty {
            summary += " Recurring terms: \(keywords.joined(separator: ", "))."
        }

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
            peopleHintRedacted: [],  // Phase 1: no diarization — no people hints at all
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

    /// Nouns that recur (>= 2 occurrences) across the window, excluding words
    /// tagged as personal/place/organization names (default redact, via the
    /// shared AmbientSalientExtractor.contentNouns). Single recurring terms
    /// are processed signal, never verbatim sentences.
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
