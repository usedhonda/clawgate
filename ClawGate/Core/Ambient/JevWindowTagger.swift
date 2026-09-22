import Foundation
import CryptoKit

/// Asks Jev the fixed `ambientWindow` questions about one 60s ambient window,
/// exactly once, and records the answers next to the rule extractor's events
/// in `JevLedger` — shadow only. Nothing this type does changes what the
/// window sends to the Gateway; it only observes the same window afterward.
struct JevWindowTagger {
    /// Why a window was not asked about.
    enum Skip: Error, Equatable {
        case empty
        case disabled
        case unconfigured
        case breakerOpen
        case alreadyAsked
    }

    enum Outcome {
        case skipped(Skip)
        case asked(JevResult)
        case failed(JevError)
    }

    var client: JevClient
    var ledger: JevLedger
    var breaker: JevBreaker
    var isEnabled: () -> Bool
    var isConfigured: () -> Bool
    /// The actual call. Defaults to `client.ask`, captured at init time so
    /// tests can stub it and never touch the network.
    var ask: (String, [String: JevQuestion]) throws -> JevResult

    init(client: JevClient = JevClient(),
         ledger: JevLedger = JevLedger(),
         breaker: JevBreaker = JevBreaker(),
         isEnabled: @escaping () -> Bool = { ConfigStore().load().jevEnabled },
         isConfigured: @escaping () -> Bool = { JevKeyStore().isConfigured },
         ask: ((String, [String: JevQuestion]) throws -> JevResult)? = nil) {
        self.client = client
        self.ledger = ledger
        self.breaker = breaker
        self.isEnabled = isEnabled
        self.isConfigured = isConfigured
        self.ask = ask ?? { state, questions in try client.ask(state: state, questions: questions) }
    }

    /// A stable key for "this exact set of segments was asked": a SHA-256 hex
    /// prefix of the ids joined in order. A retried flush of the same window
    /// (same ids, same order) always maps back to the same key, so a retry
    /// never asks Jev twice about the same speech.
    static func windowKey(segmentIds: [String]) -> String {
        let joined = segmentIds.joined(separator: "\n")
        let hex = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// The window's transcript, in the same `[HH:mm] ご主人様: …` / `相手: …`
    /// convention the questions are phrased against.
    static func state(from lines: [AmbientIngestProducer.Line], timeZone: TimeZone = .current) -> String {
        AmbientIngestProducer.dialogueSummary(lines, maxChars: 1500, timeZone: timeZone)
    }

    /// Pure gate: the window key to ask with, or the reason to skip. Checked
    /// cheapest/most-decisive first, ending on the one check that touches
    /// disk (`ledger.hasAsked`).
    func decision(segmentIds: [String], now: Date = Date()) -> Result<String, Skip> {
        guard !segmentIds.isEmpty else { return .failure(.empty) }
        guard isEnabled() else { return .failure(.disabled) }
        guard isConfigured() else { return .failure(.unconfigured) }
        guard !breaker.shouldSkip(now: now) else { return .failure(.breakerOpen) }
        let key = Self.windowKey(segmentIds: segmentIds)
        guard !ledger.hasAsked(key: key, on: now) else { return .failure(.alreadyAsked) }
        return .success(key)
    }

    /// Runs the gate, and on a go, asks Jev and records the outcome. Records
    /// a breaker attempt (success or failure) on every real call, but a skip
    /// is never recorded as an attempt — skipping because the breaker is
    /// already open must not itself extend the open window.
    mutating func tag(lines: [AmbientIngestProducer.Line], segmentIds: [String],
                       ruleEventTypes: [String], now: Date = Date()) -> Outcome {
        switch decision(segmentIds: segmentIds, now: now) {
        case .failure(let skip):
            return .skipped(skip)
        case .success(let key):
            let state = Self.state(from: lines)
            do {
                let result = try ask(state, JevQuestions.ambientWindow)
                breaker.record(ok: true, at: now)
                let entry = JevTagEntry(
                    key: key,
                    segmentIds: segmentIds,
                    questionVersion: JevQuestions.version,
                    answers: result.answers,
                    invalid: result.invalid,
                    usage: JevTagEntry.Usage(inputTokens: result.usage.inputTokens,
                                             outputTokens: result.usage.outputTokens),
                    latencyMs: result.latencyMs,
                    at: now,
                    ruleEventTypes: ruleEventTypes
                )
                ledger.record(entry)
                return .asked(result)
            } catch {
                breaker.record(ok: false, at: now)
                return .failed((error as? JevError) ?? .unexpected)
            }
        }
    }
}
