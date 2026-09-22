import Foundation
import CryptoKit

/// Shadow-scores a Log question's relevance against that day's transcript,
/// 90-second block by block, in a single Jev call — one `noul` question per
/// block, all answered together. This measures whether a cheap relevance
/// pass would agree with which segments the model itself chose to use
/// (`PetLogContextDecision.includedSegmentIds`); nothing here changes the
/// Log request, its scope, or its answer.
///
/// Unlike `JevMeetingTagger` (which splits a long meeting into several
/// sequential batches, each its own Jev call), this asks about every block
/// of the day in ONE call: the whole point is a single relevance judgment
/// that can be compared, block for block, against the one contiguous scope
/// decision the model made for the same request.
enum JevLogRelevanceLayout {
    /// Groups raw query-time segments into 90-second blocks, the same gap
    /// rule `AmbientLogGrouping.blocks` uses for display — but operating on
    /// `PetLogRawSegment` (the query envelope's segment type) rather than
    /// `TranscriptSegment`, so `AmbientLogGrouping` itself is untouched. A
    /// block closes when the gap between two consecutive timestamped
    /// segments exceeds `gapSeconds`; segments without a timestamp continue
    /// the current block (no time info to split on).
    static func groupBlocks(segments: [PetLogRawSegment], gapSeconds: Double = 90) -> [[PetLogRawSegment]] {
        var result: [[PetLogRawSegment]] = []
        var current: [PetLogRawSegment] = []
        var lastTime: Double?
        for seg in segments {
            if let t = seg.capturedAt {
                if let last = lastTime, t - last > gapSeconds, !current.isEmpty {
                    result.append(current)
                    current = []
                }
                lastTime = t
            }
            current.append(seg)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// One `noul` question per block, id `"b0"`, `"b1"`, … Each question
    /// names its own block's `[Bn]` marker explicitly (rather than asking a
    /// single generic question against the whole state) so Jev's answer for
    /// "b3" is pinned to block 3 even though every question shares the same
    /// state text. A HIGH value always means relevant, matching the
    /// `JevQuestions` polarity convention.
    static func questions(blockCount: Int, instruction: String) -> [String: JevQuestion] {
        var out: [String: JevQuestion] = [:]
        for index in 0..<max(0, blockCount) {
            let marker = "[B\(index)]"
            let id = "b\(index)"
            let text = "会話ログは [B0] [B1] … の印で区切られています。印 \(marker) の直後から次の印までの発言が、"
                + "次の質問に答えるための根拠として関係あるかどうかを判定してください。質問:「\(instruction)」 "
                + "関係が深いほど1に近い値にしてください。その区間に手がかりが全く無い場合は0.5に近い値を返してください。"
            out[id] = .noul(
                text,
                yes: "\(marker) の区間の発言が、質問に答えるための根拠として関係がある",
                no: "\(marker) の区間の発言は、質問と関係がない"
            )
        }
        return out
    }

    /// The whole day rendered once, each block preceded by its own `[Bn]`
    /// marker, lines as `[HH:mm] <speaker or ->: text`. Jev's per-call limit
    /// is 32k tokens for `state` plus the longest question, so `maxChars`
    /// stays well under that — and when the rendered state is still too
    /// long, whole blocks are dropped from the OLDEST end (never cut
    /// mid-block) since a Log question is usually about the most recent
    /// conversation, kept intact.
    static func state(blocks: [[PetLogRawSegment]], maxChars: Int = 24_000,
                      timeZone: TimeZone = .current) -> String {
        guard !blocks.isEmpty else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.timeZone = timeZone

        func render(_ block: [PetLogRawSegment], index: Int) -> String {
            var lines = ["[B\(index)]"]
            for seg in block {
                let time = seg.capturedAt.map { fmt.string(from: Date(timeIntervalSince1970: $0)) } ?? "--:--"
                let speaker = seg.speaker ?? "-"
                lines.append("[\(time)] \(speaker): \(seg.text)")
            }
            return lines.joined(separator: "\n")
        }

        let rendered = blocks.enumerated().map { render($0.element, index: $0.offset) }
        var start = 0
        func length(from index: Int) -> Int {
            rendered[index...].joined(separator: "\n\n").count
        }
        // Drop whole oldest blocks while over budget — but never drop the
        // last remaining block, so a single oversized block is still sent
        // rather than producing an empty state.
        while start < rendered.count - 1 && length(from: start) > maxChars {
            start += 1
        }
        return rendered[start...].joined(separator: "\n\n")
    }
}

/// One shadow-scoring record for one Log request: the owner's own question
/// text (safe to store — never transcript text), the block/segment-id
/// layout it was asked against, and either Jev's per-block scores or why it
/// was skipped. `modelIncludedSegmentIds` is filled in later, by a second
/// append (`JevLogRelevanceStore.attachModelDecision`), once the model's own
/// `PetLogContextDecision` for the SAME request is known — appending is
/// simpler and safer than rewriting the earlier line in place.
struct LogRelevanceShadow: Codable, Equatable {
    var requestId: String
    var at: Date
    var questionVersion: Int
    var instruction: String
    var blockSegmentIds: [[String]]
    var scores: [String: Double]
    var invalid: [String]
    var skipped: String?
    var modelIncludedSegmentIds: [String]?
}

/// Runs the shadow relevance pass for one Log query envelope. Follows the
/// exact same gate order as `JevWindowTagger.decision` (empty -> disabled ->
/// unconfigured -> breakerOpen -> alreadyAsked), but the "already asked" key
/// is hashed over BOTH the segment ids and the owner's instruction text —
/// unlike an ambient window, the same day's segments can legitimately be
/// asked about more than once, under a different question, and each
/// question deserves its own shadow score.
struct JevLogRelevance {
    /// Why a shadow pass did not ask Jev anything.
    enum Skip: String, Equatable {
        case empty
        case disabled
        case unconfigured
        case breakerOpen
        case alreadyAsked
        case failed
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

    /// The dedupe key for "this exact segment set, asked about this exact
    /// question, was already shadow-scored": a SHA-256 hex prefix of the
    /// segment ids and the instruction hashed together, so a different
    /// question over the same day is still asked (unlike
    /// `JevWindowTagger.windowKey`, which keys on segment ids alone).
    static func requestKey(segmentIds: [String], instruction: String) -> String {
        let joined = (segmentIds + [instruction]).joined(separator: "\n")
        let hex = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    func shadow(envelope: PetLogQueryEnvelope, blocks: [[PetLogRawSegment]], now: Date = Date()) -> LogRelevanceShadow {
        let allIds = envelope.segments.map(\.id)
        let blockSegmentIds = blocks.map { $0.map(\.id) }

        func skipped(_ reason: Skip) -> LogRelevanceShadow {
            LogRelevanceShadow(requestId: envelope.requestId, at: now, questionVersion: JevQuestions.version,
                               instruction: envelope.instruction, blockSegmentIds: blockSegmentIds,
                               scores: [:], invalid: [], skipped: reason.rawValue, modelIncludedSegmentIds: nil)
        }

        guard !allIds.isEmpty, !blocks.isEmpty else { return skipped(.empty) }
        guard isEnabled() else { return skipped(.disabled) }
        guard isConfigured() else { return skipped(.unconfigured) }
        guard !breaker.shouldSkip(now: now) else { return skipped(.breakerOpen) }
        let key = Self.requestKey(segmentIds: allIds, instruction: envelope.instruction)
        guard !ledger.hasAsked(key: key, on: now) else { return skipped(.alreadyAsked) }

        let state = JevLogRelevanceLayout.state(blocks: blocks)
        let questions = JevLogRelevanceLayout.questions(blockCount: blocks.count, instruction: envelope.instruction)
        do {
            let result = try ask(state, questions)
            var breaker = self.breaker
            breaker.record(ok: true, at: now)
            let entry = JevTagEntry(
                key: key,
                segmentIds: allIds,
                questionVersion: JevQuestions.version,
                answers: result.answers,
                invalid: result.invalid,
                usage: JevTagEntry.Usage(inputTokens: result.usage.inputTokens, outputTokens: result.usage.outputTokens),
                latencyMs: result.latencyMs,
                at: now,
                ruleEventTypes: nil
            )
            ledger.record(entry)
            return LogRelevanceShadow(requestId: envelope.requestId, at: now, questionVersion: JevQuestions.version,
                                      instruction: envelope.instruction, blockSegmentIds: blockSegmentIds,
                                      scores: result.answers, invalid: result.invalid, skipped: nil,
                                      modelIncludedSegmentIds: nil)
        } catch {
            var breaker = self.breaker
            breaker.record(ok: false, at: now)
            return skipped(.failed)
        }
    }
}

/// One appended JSONL line attaching the model's own segment choice to an
/// already-written `LogRelevanceShadow`, joined later by `requestId`.
private struct JevLogRelevanceModelDecision: Codable, Equatable {
    var requestId: String
    var modelIncludedSegmentIds: [String]
    var at: Date
}

/// A day's worth of shadow-relevance records, joined by `requestId`.
struct JevLogRelevanceRecord: Equatable {
    var shadow: LogRelevanceShadow?
    var modelIncludedSegmentIds: [String]?
}

/// Append-only JSONL store for `LogRelevanceShadow` records, one file per
/// local day (the Mac's current calendar, matching `JevLedger`'s idiom) at
/// `AmbientStorage.ambientRoot/jev/log-relevance-YYYY-MM-DD.jsonl`. Appending
/// a shadow and appending its later model-decision attachment are two
/// separate lines — simpler and safer than rewriting the earlier line once
/// the model's reply arrives (which may be much later, or never, if the
/// reply times out).
enum JevLogRelevanceStore {
    static func append(_ shadow: LogRelevanceShadow, root: URL = AmbientStorage.ambientRoot) {
        guard let line = try? encode(shadow) else { return }
        appendLine(line, for: shadow.at, root: root)
    }

    static func attachModelDecision(requestId: String, includedSegmentIds: [String], at: Date = Date(),
                                    root: URL = AmbientStorage.ambientRoot) {
        let record = JevLogRelevanceModelDecision(requestId: requestId, modelIncludedSegmentIds: includedSegmentIds, at: at)
        guard let line = try? encode(record) else { return }
        appendLine(line, for: at, root: root)
    }

    /// Reads one day's file and joins shadow lines with their (possibly
    /// absent, possibly later-appended) model-decision line by `requestId`.
    static func readJoined(day: Date, root: URL = AmbientStorage.ambientRoot) -> [String: JevLogRelevanceRecord] {
        let url = fileURL(for: day, root: root)
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [String: JevLogRelevanceRecord] = [:]
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let shadow = try? decoder.decode(LogRelevanceShadow.self, from: lineData) {
                var record = out[shadow.requestId] ?? JevLogRelevanceRecord()
                record.shadow = shadow
                out[shadow.requestId] = record
                continue
            }
            if let attach = try? decoder.decode(JevLogRelevanceModelDecision.self, from: lineData) {
                var record = out[attach.requestId] ?? JevLogRelevanceRecord()
                record.modelIncludedSegmentIds = attach.modelIncludedSegmentIds
                out[attach.requestId] = record
            }
        }
        return out
    }

    private static func fileURL(for date: Date, root: URL) -> URL {
        root.appendingPathComponent("jev", isDirectory: true)
            .appendingPathComponent("log-relevance-\(dayString(date)).jsonl", isDirectory: false)
    }

    private static func dayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = .current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private static func appendLine(_ line: String, for date: Date, root: URL) {
        let dir = root.appendingPathComponent("jev", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = fileURL(for: date, root: root)
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data)
        }
    }

    private static func encode(_ shadow: LogRelevanceShadow) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(shadow)
        guard let s = String(data: data, encoding: .utf8) else { throw JevError.unexpected }
        return s
    }

    private static func encode(_ record: JevLogRelevanceModelDecision) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        guard let s = String(data: data, encoding: .utf8) else { throw JevError.unexpected }
        return s
    }
}
