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

    func send(reminderId: String, outcome: String, at: Date = Date()) {
        guard var components = URLComponents(string: "http://\(host):\(port)") else { return }
        components.path = "/api/reminder-receipt"
        guard let url = components.url else { return }
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
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                log("reminder receipt failed \(reminderId) \(outcome): \(error)")
            } else if !(200...299).contains(status) {
                log("reminder receipt rejected \(reminderId) \(outcome): HTTP \(status)")
            }
        }.resume()
    }
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

    init(synthesizer: VoicevoxSynthesizer = VoicevoxSynthesizer(),
         memory: ReminderMemory = ReminderMemory(),
         receipts: @escaping () -> ReminderReceiptClient?,
         log: @escaping (String) -> Void = { _ in }) {
        self.synthesizer = synthesizer
        self.memory = memory
        self.receipts = receipts
        self.log = log
    }

    /// Entry point for a chat payload that may carry a reminder. Returns true
    /// when the payload was one (so the caller knows it was handled here).
    @discardableResult
    func handle(_ payload: ReminderPayload, now: Date = Date()) -> Bool {
        switch ReminderReadoutDecider.decide(payload, now: now, seen: memory.ids(now: now)) {
        case .ignore:
            return false
        case .skip(let id, let outcome):
            log("reminder \(id) \(outcome)")
            receipts()?.send(reminderId: id, outcome: outcome)
            return true
        case .speak(let id, let speech):
            // Claim it before speaking: a second copy arriving while this one is
            // still being synthesized must not start a second readout.
            memory.remember(id, now: now)
            queue.async { [weak self] in self?.speak(id: id, speech: speech) }
            return true
        }
    }

    private func speak(id: String, speech: String) {
        if let blocked = ReminderAudioOutput.blockingOutcome() {
            log("reminder \(id) \(blocked)")
            receipts()?.send(reminderId: id, outcome: blocked)
            return
        }
        let wav: Data
        do {
            wav = try synthesizer.synthesize(speech)
        } catch {
            let outcome = "failed:synthesis"
            log("reminder \(id) \(outcome): \(error)")
            receipts()?.send(reminderId: id, outcome: outcome)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                let player = try AVAudioPlayer(data: wav)
                self.player = player
                guard player.play() else { throw ReminderPlaybackError.playRefused }
                self.log("reminder \(id) played")
                self.receipts()?.send(reminderId: id, outcome: "played")
            } catch {
                let outcome = "failed:playback"
                self.log("reminder \(id) \(outcome): \(error)")
                self.receipts()?.send(reminderId: id, outcome: outcome)
            }
        }
    }
}

enum ReminderPlaybackError: Error { case playRefused }
