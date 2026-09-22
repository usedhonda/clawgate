import AVFoundation
import Foundation

/// Sends one receipt per reminder that was addressed to this Mac.
///
/// The Gateway keeps these in a daily log and its doctor warns when the readout
/// is switched on but nothing has played for a day — so a receipt that never
/// arrives is worse than a reminder that never sounded. The body carries the id
/// and the outcome only: never the script, never the display text.
struct ReminderReceiptClient {
    var host: String
    var port: Int
    var token: String?
    var timeout: TimeInterval = 10
    var log: (String) -> Void = { _ in }

    /// The receipt goes to the Gateway this Mac already talks to, which is a
    /// different machine — a literal 127.0.0.1 would post into a port nothing
    /// listens on here and leave the Gateway's log permanently empty.
    static func fromConfig(_ config: AppConfig, log: @escaping (String) -> Void = { _ in }) -> ReminderReceiptClient? {
        let host = config.openclawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        return ReminderReceiptClient(host: host, port: config.openclawPort,
                                     token: OpenClawGatewayInfo.load()?.token, log: log)
    }

    /// `completion` reports the receipt POST's own outcome (HTTP status, or the
    /// transport error's class name) — used only to keep a diagnostic trace up
    /// to date, never for control flow.
    func send(reminderId: String, outcome: String, at: Date = Date(),
              completion: ((Int?, String?) -> Void)? = nil) {
        guard var components = URLComponents(string: "http://\(host):\(port)") else {
            completion?(nil, "bad_host")
            return
        }
        components.path = "/api/reminder-receipt"
        guard let url = components.url else {
            completion?(nil, "bad_url")
            return
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.formatOptions = [.withInternetDateTime]
        let body: [String: String] = [
            "reminderId": reminderId,
            "outcome": outcome,
            "at": iso.string(from: at),
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            if let error {
                log("reminder receipt failed \(reminderId) \(outcome): \(error)")
                completion?(status, String(describing: type(of: error)))
            } else if let status, !(200...299).contains(status) {
                log("reminder receipt rejected \(reminderId) \(outcome): HTTP \(status)")
                completion?(status, nil)
            } else {
                completion?(status, nil)
            }
        }.resume()
    }
}

/// One reminder payload's path through `ReminderReadoutService`, kept for
/// after-the-fact diagnosis. No speech text, key, or other payload body ever
/// goes in here — only ids and the agreed outcome vocabulary.
struct ReminderTrace: Codable, Equatable {
    var at: Date
    var reminderId: String?
    var kind: String?
    var speakOn: String?
    var expiresAt: String?
    var decision: String
    var outcome: String?
    var receiptStatus: Int?
    var receiptError: String?
    /// This process's pid and the moment it was first observed by this type
    /// (a `static let`, so every trace this process writes carries the same
    /// pair). Two lines for the same reminder with different pids prove a
    /// second process ran between them; a gap in the trace with one pid
    /// unchanged rules that out and points at an in-memory loss instead.
    var pid: Int32
    var processStartedAt: Date
}

/// Remembers which reminders have already been read, so a resend or a
/// reconnect does not read the same one twice. Persisted: an app restart is
/// exactly when a resend is most likely.
struct ReminderMemory {
    static let key = "clawgate.reminder.spoken"
    static let retention: TimeInterval = 24 * 3600

    var defaults: UserDefaults = .standard

    func ids(now: Date = Date()) -> Set<String> {
        Set(stored(now: now).keys)
    }

    func remember(_ id: String, now: Date = Date()) {
        var map = stored(now: now)
        map[id] = now.timeIntervalSince1970
        defaults.set(map, forKey: Self.key)
    }

    /// Stored ids with anything past the retention window dropped.
    private func stored(now: Date) -> [String: Double] {
        let raw = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        let cutoff = now.timeIntervalSince1970 - Self.retention
        return raw.filter { $0.value >= cutoff }
    }
}

/// Ties the reminder path together: decide, synthesize, play, report.
final class ReminderReadoutService {
    private let synthesizer: VoicevoxSynthesizer
    private let receipts: () -> ReminderReceiptClient?
    private let memory: ReminderMemory
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "ai.clawgate.reminder")
    /// AVAudioPlayer stops the moment it is released, so it is held until the
    /// clip has finished.
    private var player: AVAudioPlayer?

    /// The one readout for this process. ClawGate holds two Gateway
    /// connections — `PetModel`'s own `OpenClawWSClient` and
    /// `AmbientIngestProducer`'s separate one for `ambient.ingest` — and both
    /// authenticate as the same device identity, so the Gateway sees one
    /// device and a `broadcast("chat")` reminder lands on whichever socket
    /// happens to be open. Observed 2026-09-22: a live test fired three
    /// reminders and the ingest socket silently dropped two of them, because
    /// its drain loop only switched on `.connected`/`.disconnected`. Routing
    /// both connections' `.reminder` events to this single shared instance
    /// means it no longer matters which socket receives the broadcast. Also
    /// read by `BridgeCore` for `/v1/debug/reminders`, without a direct
    /// reference to `PetModel`.
    static let shared = ReminderReadoutService(
        receipts: { ReminderReceiptClient.fromConfig(ConfigStore().load()) { NSLog("[Reminder] %@", $0) } },
        log: { NSLog("[Reminder] %@", $0) }
    )

    /// Last 50 reminder decisions, newest first, for `/v1/debug/reminders`.
    /// Never carries speech text or the receipt token — ids and the agreed
    /// outcome vocabulary only.
    private var traces: [ReminderTrace] = []
    private let tracesLock = NSLock()
    private static let maxTraces = 50
    /// Where this instance mirrors every trace to disk. Injectable so tests
    /// never touch the real Application Support tree.
    private let traceStoreRoot: URL

    /// This process's pid and real start time, so two traces can be told apart
    /// as "same process" or "a process that restarted in between". See
    /// `ProcessIdentity`, which every restart-spanning diagnostic shares.
    static let processPid = ProcessIdentity.pid
    static let processStartedAt = ProcessIdentity.startedAt

    init(synthesizer: VoicevoxSynthesizer = VoicevoxSynthesizer(),
         memory: ReminderMemory = ReminderMemory(),
         receipts: @escaping () -> ReminderReceiptClient?,
         log: @escaping (String) -> Void = { _ in },
         traceStoreRoot: URL = ReminderTraceStore.root) {
        self.synthesizer = synthesizer
        self.memory = memory
        self.receipts = receipts
        self.log = log
        self.traceStoreRoot = traceStoreRoot
    }

    /// Newest first, from the in-memory ring buffer only (the fast path).
    func recentTraces() -> [ReminderTrace] {
        tracesLock.lock()
        defer { tracesLock.unlock() }
        return traces
    }

    /// Newest first, merged from memory and disk and deduped by
    /// `(reminderId, at)` — so `/v1/debug/reminders` can still answer a
    /// trace that memory has already lost, whatever the cause. What this
    /// process still holds in memory is authoritative over what is on disk
    /// for the same key.
    func recentTracesMerged(limit: Int = maxTraces) -> [ReminderTrace] {
        let diskTraces = ReminderTraceStore.recent(limit: limit, root: traceStoreRoot)
        var byKey: [String: ReminderTrace] = [:]
        for trace in diskTraces { byKey[ReminderTraceStore.dedupeKey(trace)] = trace }
        for trace in recentTraces() { byKey[ReminderTraceStore.dedupeKey(trace)] = trace }
        return Array(byKey.values.sorted { $0.at > $1.at }.prefix(limit))
    }

    private func recordTrace(_ trace: ReminderTrace) {
        tracesLock.lock()
        traces.insert(trace, at: 0)
        if traces.count > Self.maxTraces {
            traces.removeLast(traces.count - Self.maxTraces)
        }
        tracesLock.unlock()
        ReminderTraceStore.append(trace, root: traceStoreRoot)
    }

    /// Matches the most recent trace for `reminderId` — safe because a given
    /// id is claimed in `memory` before it is spoken, so at most one "speak"
    /// trace exists per id for the life of this service. The updated copy is
    /// also appended to disk as a new line — the store is append-only, never
    /// rewritten in place.
    private func updateTrace(reminderId: String, outcome: String? = nil,
                              receiptStatus: Int?? = nil, receiptError: String?? = nil) {
        tracesLock.lock()
        guard let index = traces.firstIndex(where: { $0.reminderId == reminderId }) else {
            tracesLock.unlock()
            return
        }
        if let outcome { traces[index].outcome = outcome }
        if let receiptStatus { traces[index].receiptStatus = receiptStatus }
        if let receiptError { traces[index].receiptError = receiptError }
        let updated = traces[index]
        tracesLock.unlock()
        ReminderTraceStore.append(updated, root: traceStoreRoot)
    }

    private func receiptCompletion(for id: String) -> (Int?, String?) -> Void {
        { [weak self] status, error in
            self?.updateTrace(reminderId: id, receiptStatus: .some(status), receiptError: .some(error))
        }
    }

    /// Entry point for a chat payload that may carry a reminder. Returns true
    /// when the payload was one (so the caller knows it was handled here).
    @discardableResult
    func handle(_ payload: ReminderPayload, now: Date = Date()) -> Bool {
        let decision = ReminderReadoutDecider.decide(payload, now: now, seen: memory.ids(now: now))
        func trace(decision: String, outcome: String?, reminderId: String?) -> ReminderTrace {
            ReminderTrace(at: now, reminderId: reminderId, kind: payload.kind, speakOn: payload.speakOn,
                          expiresAt: payload.expiresAt, decision: decision, outcome: outcome,
                          receiptStatus: nil, receiptError: nil,
                          pid: Self.processPid, processStartedAt: Self.processStartedAt)
        }
        switch decision {
        case .ignore:
            recordTrace(trace(decision: "ignore", outcome: nil, reminderId: payload.reminderId))
            return false
        case .skip(let id, let outcome):
            log("reminder \(id) \(outcome)")
            recordTrace(trace(decision: outcome, outcome: outcome, reminderId: id))
            receipts()?.send(reminderId: id, outcome: outcome, completion: receiptCompletion(for: id))
            return true
        case .speak(let id, let speech):
            // Claim it before speaking: a second copy arriving while this one is
            // still being synthesized must not start a second readout.
            memory.remember(id, now: now)
            recordTrace(trace(decision: "speak", outcome: nil, reminderId: id))
            queue.async { [weak self] in self?.speak(id: id, speech: speech) }
            return true
        }
    }

    private func speak(id: String, speech: String) {
        if let blocked = ReminderAudioOutput.blockingOutcome() {
            log("reminder \(id) \(blocked)")
            updateTrace(reminderId: id, outcome: blocked)
            receipts()?.send(reminderId: id, outcome: blocked, completion: receiptCompletion(for: id))
            return
        }
        let wav: Data
        do {
            wav = try synthesizer.synthesize(speech)
        } catch {
            let outcome = "failed:synthesis"
            log("reminder \(id) \(outcome): \(error)")
            updateTrace(reminderId: id, outcome: outcome)
            receipts()?.send(reminderId: id, outcome: outcome, completion: receiptCompletion(for: id))
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                let player = try AVAudioPlayer(data: wav)
                self.player = player
                guard player.play() else { throw ReminderPlaybackError.playRefused }
                self.log("reminder \(id) played")
                self.updateTrace(reminderId: id, outcome: "played")
                self.receipts()?.send(reminderId: id, outcome: "played", completion: self.receiptCompletion(for: id))
            } catch {
                let outcome = "failed:playback"
                self.log("reminder \(id) \(outcome): \(error)")
                self.updateTrace(reminderId: id, outcome: outcome)
                self.receipts()?.send(reminderId: id, outcome: outcome, completion: self.receiptCompletion(for: id))
            }
        }
    }
}

enum ReminderPlaybackError: Error { case playRefused }
