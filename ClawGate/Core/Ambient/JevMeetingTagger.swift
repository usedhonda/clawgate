import Foundation

/// Shadow-tags a whole meeting's transcript with Jev's fixed ambient
/// questions, batch by batch, and stores the answers next to the minutes —
/// nothing here changes what minutes are requested or what they say.
///
/// A meeting can run for hours, but Jev's `state` has a 32k-token budget per
/// call, so the transcript is split into contiguous batches first and each
/// batch is asked about through `JevWindowTagger` exactly as an ambient
/// window would be (same gate, same ledger, same breaker).
struct JevMeetingTagger {
    /// Injectable so tests can stub the underlying `ask` call without
    /// touching the network. Defaults to a fresh, unconfigured tagger; the
    /// caller normally overrides this with one built the same way the
    /// ambient pipeline builds its own.
    var makeTagger: () -> JevWindowTagger = { JevWindowTagger() }

    /// Splits `segments` into contiguous, order-preserving batches. A batch
    /// closes — and a new one starts — when adding the next segment would
    /// push it past either cap; a batch is never reordered or split apart
    /// from the segments it already holds.
    static func batches(_ segments: [TranscriptSegment], maxChars: Int = 6_000,
                        maxSegments: Int = 80) -> [[TranscriptSegment]] {
        guard !segments.isEmpty else { return [] }
        var result: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var currentChars = 0
        for segment in segments {
            let segmentChars = segment.text.count
            if !current.isEmpty && (currentChars + segmentChars > maxChars || current.count + 1 > maxSegments) {
                result.append(current)
                current = []
                currentChars = 0
            }
            current.append(segment)
            currentChars += segmentChars
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Tags every batch in order and rolls the answers up into one shadow
    /// record. Synchronous — the same shape as `JevWindowTagger.tag` — so the
    /// caller is responsible for running it off the main thread.
    ///
    /// A batch that comes back `.skipped(.breakerOpen)` means the breaker is
    /// open for everyone, not just this batch, so the remaining batches are
    /// marked `skipped: "breakerOpen"` without another call.
    func shadow(record: MeetingRecord, segments: [TranscriptSegment], now: Date = Date()) -> MeetingJevShadow {
        var tagger = makeTagger()
        let allBatches = Self.batches(segments)
        var batchShadows: [BatchShadow] = []
        var peak: [String: Double] = [:]

        for (index, batch) in allBatches.enumerated() {
            let ids = batch.map { PetLogSegmentID.make(for: $0) }
            let key = JevWindowTagger.windowKey(segmentIds: ids)
            let lines = batch.map { segment in
                AmbientIngestProducer.Line(text: segment.text, speaker: segment.speaker,
                                           capturedAt: segment.capturedAt.map(Date.init(timeIntervalSince1970:)),
                                           speakerName: segment.speakerName)
            }
            let outcome = tagger.tag(lines: lines, segmentIds: ids, ruleEventTypes: [], now: now)
            switch outcome {
            case .asked(let result):
                batchShadows.append(BatchShadow(key: key, segmentIds: ids, answers: result.answers,
                                                invalid: result.invalid, skipped: nil))
                for (question, value) in result.answers {
                    peak[question] = max(peak[question] ?? value, value)
                }
            case .skipped(let skip):
                batchShadows.append(BatchShadow(key: key, segmentIds: ids, answers: [:], invalid: [],
                                                skipped: "\(skip)"))
                if skip == .breakerOpen {
                    for remaining in allBatches[(index + 1)...] {
                        let remainingIds = remaining.map { PetLogSegmentID.make(for: $0) }
                        let remainingKey = JevWindowTagger.windowKey(segmentIds: remainingIds)
                        batchShadows.append(BatchShadow(key: remainingKey, segmentIds: remainingIds,
                                                        answers: [:], invalid: [], skipped: "breakerOpen"))
                    }
                    return MeetingJevShadow(meetingId: record.id, questionVersion: JevQuestions.version,
                                            at: now, batches: batchShadows, peak: peak)
                }
            case .failed(let error):
                batchShadows.append(BatchShadow(key: key, segmentIds: ids, answers: [:], invalid: [],
                                                skipped: "failed:\(error)"))
            }
        }
        return MeetingJevShadow(meetingId: record.id, questionVersion: JevQuestions.version,
                                at: now, batches: batchShadows, peak: peak)
    }
}

/// One batch's outcome, as stored in `jev.json`.
struct BatchShadow: Codable, Equatable {
    var key: String
    var segmentIds: [String]
    var answers: [String: Double]
    var invalid: [String]
    var skipped: String?
}

/// A whole meeting's Jev shadow: every batch plus the per-question peak
/// across them — the meeting-level signal a later comparison against the
/// model's own decisions and action items will use.
struct MeetingJevShadow: Codable, Equatable {
    var meetingId: String
    var questionVersion: Int
    var at: Date
    var batches: [BatchShadow]
    var peak: [String: Double]
}

extension MeetingStore {
    /// `meetings/<id>/jev.json`, the same file-writing idiom as
    /// `saveMinutes` — a failed write is recoverable, since shadow tagging
    /// can simply run again on the next request.
    func saveJevShadow(_ shadow: MeetingJevShadow, for record: MeetingRecord) {
        let dir = directory(for: record.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(shadow).write(to: dir.appendingPathComponent("jev.json"), options: .atomic)
        } catch {
            // Losing the file is recoverable: shadow tagging can run again.
        }
    }

    func loadJevShadow(id: String) -> MeetingJevShadow? {
        let url = directory(for: id).appendingPathComponent("jev.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingJevShadow.self, from: data)
    }
}
