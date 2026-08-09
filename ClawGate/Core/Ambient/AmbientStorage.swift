import Foundation

// Local on-disk layout for the Ambient Context Stream. All audio and
// transcripts live under Application Support, never inside the repository.
//
//   ~/Library/Application Support/ClawGate/ambient-context/
//     rolling/<YYYY-MM-DD>/chunk-000001.wav ...
//     sessions/<session_id>/{audio,transcripts}/
//   ~/Library/Application Support/ClawGate/whisper/
//     bin/whisper-cli
//     models/ggml-large-v3-turbo.bin
enum AmbientStorage {
    private struct SessionSegmentsCache {
        let rawPath: String
        let modificationDate: Date?
        let fileSize: UInt64
        let segments: [TranscriptSegment]
        // D159: lines/files that could not be read or decoded (malformed JSONL,
        // unreadable bytes) — a source-completeness signal the caller fails
        // closed on. Cached alongside the segments so a re-read is consistent.
        let decodeFailures: Int
    }

    private static var sessionSegmentsCache: [String: SessionSegmentsCache] = [:]
    // D42: `segments(forDay:)` now runs off the main thread (D21) and can be
    // called concurrently for different days/roots, so the process-global cache
    // needs synchronization. The lock guards only the dictionary; the heavy
    // decode I/O runs OUTSIDE it (two-phase: check under lock, decode unlocked,
    // re-store under lock).
    private static let cacheLock = NSLock()

    /// Returns the decoded segments for one session's `raw.jsonl`, served from
    /// the shared cache when the (path, mod-date, size) fingerprint still
    /// matches. The decode happens outside the lock so a slow read never blocks
    /// a concurrent reader of a different session.
    private static func cachedSessionSegments(rawPath: String,
                                              modificationDate: Date?,
                                              fileSize: UInt64) -> (segments: [TranscriptSegment], decodeFailures: Int) {
        cacheLock.lock()
        if let cached = sessionSegmentsCache[rawPath],
           cached.rawPath == rawPath,
           cached.modificationDate == modificationDate,
           cached.fileSize == fileSize {
            let result = (cached.segments, cached.decodeFailures)
            cacheLock.unlock()
            return result
        }
        cacheLock.unlock()

        // Heavy decode, off-lock.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: rawPath)),
              let text = String(data: data, encoding: .utf8) else {
            // The file was stat'd by the caller but its bytes can't be read or
            // decoded as UTF-8 — a source read failure (D159), not "no records".
            let entry = SessionSegmentsCache(rawPath: rawPath, modificationDate: modificationDate,
                                             fileSize: fileSize, segments: [], decodeFailures: 1)
            cacheLock.lock(); sessionSegmentsCache[rawPath] = entry; cacheLock.unlock()
            return ([], 1)
        }
        let decoder = JSONDecoder()
        var segs: [TranscriptSegment] = []
        var decodeFailures = 0
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let d = line.data(using: .utf8),
                  let seg = try? decoder.decode(TranscriptSegment.self, from: d) else {
                decodeFailures += 1
                continue
            }
            segs.append(seg)
        }

        cacheLock.lock()
        // Another thread may have populated an equal entry meanwhile; the
        // (mod,size) fingerprint decides validity, so overwriting is safe.
        sessionSegmentsCache[rawPath] = SessionSegmentsCache(
            rawPath: rawPath, modificationDate: modificationDate, fileSize: fileSize,
            segments: segs, decodeFailures: decodeFailures)
        cacheLock.unlock()
        return (segs, decodeFailures)
    }

    static var appSupportRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClawGate", isDirectory: true)
    }

    static var ambientRoot: URL {
        appSupportRoot.appendingPathComponent("ambient-context", isDirectory: true)
    }

    static var rollingRoot: URL {
        ambientRoot.appendingPathComponent("rolling", isDirectory: true)
    }

    static var sessionsRoot: URL {
        ambientRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    // whisper.cpp provisioning (set up out-of-repo under Application Support).
    static var whisperRoot: URL {
        appSupportRoot.appendingPathComponent("whisper", isDirectory: true)
    }

    static var defaultWhisperBinary: URL {
        whisperRoot.appendingPathComponent("bin/whisper-cli", isDirectory: false)
    }

    static var defaultWhisperModel: URL {
        whisperRoot.appendingPathComponent("models/ggml-large-v3-turbo.bin", isDirectory: false)
    }

    /// Silero VAD model for whisper.cpp --vad (the root hallucination fix).
    static var defaultVADModel: URL {
        whisperRoot.appendingPathComponent("models/ggml-silero-v5.1.2.bin", isDirectory: false)
    }

    // Speaker diarization helper (separate binary — the app stays macOS 12 /
    // universal while the helper needs macOS 14+/Apple Silicon; absent helper
    // simply means no speaker labels).
    static var diarizerRoot: URL {
        appSupportRoot.appendingPathComponent("diarizer", isDirectory: true)
    }

    static var defaultDiarizerBinary: URL {
        diarizerRoot.appendingPathComponent("bin/clawgate-diarizer", isDirectory: false)
    }

    /// Enrolled "self" voiceprint (ご主人様) produced by `clawgate-diarizer enroll`.
    static var defaultSelfVoiceprint: URL {
        diarizerRoot.appendingPathComponent("self.json", isDirectory: false)
    }

    @discardableResult
    static func ensureDir(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Rolling directory for a given calendar day (UTC), e.g. rolling/2026-06-09/.
    static func rollingDir(for date: Date) -> URL {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        return rollingRoot.appendingPathComponent(fmt.string(from: date), isDirectory: true)
    }

    static func sessionDir(_ sessionID: String) -> URL {
        sessionsRoot.appendingPathComponent(sessionID, isDirectory: true)
    }

    /// All kept transcript segments captured on the given local calendar day,
    /// merged across every session and sorted by capture time. Sessions live
    /// until app restart, so one session can straddle midnight — the day is
    /// selected per-segment via `capturedAt`, never by the session-id date.
    /// Legacy lines without `capturedAt` are excluded.
    static func segments(forDay day: Date, timeZone: TimeZone) -> [TranscriptSegment] {
        segments(forDay: day, timeZone: timeZone, sessionsRoot: sessionsRoot)
    }

    /// Testable overload reading from an injected sessions root, so tests never
    /// touch the real Application Support tree.
    static func segments(forDay day: Date, timeZone: TimeZone, sessionsRoot: URL) -> [TranscriptSegment] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let startEpoch = dayStart.timeIntervalSince1970
        let endEpoch = dayEnd.timeIntervalSince1970

        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        var out: [TranscriptSegment] = []
        for dir in dirs where dir.lastPathComponent.hasPrefix("ctx-") {
            let raw = dir.appendingPathComponent("transcripts/raw.jsonl")
            let attrs = try? fm.attributesOfItem(atPath: raw.path)
            let fileSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let mod = attrs?[.modificationDate] as? Date
            // Skip sessions whose transcript was last written before this day
            // started: they cannot hold segments from it. A session that crossed
            // midnight keeps a newer mod time, so it is still read (safe side).
            if let mod, mod < dayStart { continue }
            let decoded = cachedSessionSegments(rawPath: raw.path, modificationDate: mod, fileSize: fileSize).segments
            for seg in decoded {
                guard let at = seg.capturedAt else { continue }
                if at >= startEpoch && at < endEpoch {
                    out.append(seg)
                }
            }
        }
        out.sort { ($0.capturedAt ?? 0) < ($1.capturedAt ?? 0) }
        return out
    }

    /// D38: a cheap fingerprint of a day's on-disk state — the (name, size,
    /// mod-time) of every session file that could hold this day, with NO decode.
    /// A cached past day is invalidated when this changes, so a late STT write,
    /// recovery, or backfill that grows a past day's raw is picked up instead of
    /// being hidden behind the "past days are static" cache. The mod-time is kept
    /// at FULL sub-second precision so a same-second, same-size rewrite (content
    /// corrected without changing byte count) still changes the fingerprint —
    /// truncating to whole seconds would let such a rewrite collide and hide.
    static func dayFingerprint(forDay day: Date, timeZone: TimeZone,
                               sessionsRoot: URL = AmbientStorage.sessionsRoot) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayStartEpoch = cal.startOfDay(for: day).timeIntervalSince1970
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return "empty"
        }
        var parts: [String] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where dir.lastPathComponent.hasPrefix("ctx-") {
            let raw = dir.appendingPathComponent("transcripts/raw.jsonl")
            let attrs = try? fm.attributesOfItem(atPath: raw.path)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            // Same "could this session hold this day" rule as segments(forDay:).
            if mod < dayStartEpoch { continue }
            // Full-precision mod-time (not Int(mod)) so a sub-second late rewrite
            // is not truncated into a collision. Encoded via bitPattern for an
            // exact, locale-independent, round-trip-stable representation.
            parts.append("\(dir.lastPathComponent):\(size):\(mod.bitPattern)")
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: "|")
    }

    /// Result of a single backward scan of the retained sessions relative to an
    /// anchor — the in-window segments plus typed completeness signals gathered
    /// in the SAME pass (no extra I/O). D153/D159/D163 all consume this.
    struct BackwardScan {
        /// Segments captured in `[anchor - cap, anchor)`, ordered by capturedAt.
        let window: [TranscriptSegment]
        /// D153: true when retained data OLDER than the cap exists — the
        /// automatic window may have cut off the start of the conversation. The
        /// model, not storage, decides whether that older run is the same
        /// conversation; this only reports that older history exists. Determined
        /// from `capturedAt` (never file mtime).
        let truncatedBeforeCoverage: Bool
        /// D163: segments (in-window or older) whose `capturedAt` is missing — an
        /// undated real utterance the anchor cutoff can't be verified against.
        let missingTimestampCount: Int
        /// D159: `ctx-` sessions whose raw transcript could not be stat/read at
        /// all (distinct from an absent sessions root = "no records").
        let readFailureCount: Int
        /// D159: raw lines/files that failed to read or JSON-decode (malformed
        /// JSONL, unreadable bytes) — counted during the same decode pass.
        let decodeFailureCount: Int

        /// D159/D163: any source-completeness issue that must fail the query
        /// closed rather than silently sending a partial/undated view.
        var hasSourceIssue: Bool {
            missingTimestampCount > 0 || readFailureCount > 0 || decodeFailureCount > 0
        }
    }

    /// D153: the automatic-scope retrieval source — a SINGLE pass over every
    /// retained session's raw transcript, partitioned by `capturedAt` (never
    /// file mtime). Returns the in-window segments and `truncatedBeforeCoverage`
    /// (older retained data exists). Storage never treats a time gap as a
    /// semantic boundary — deciding which leading run to exclude is the model's
    /// job; storage only reports whether history exists beyond the returned
    /// window. Source issues (missing timestamps, unreadable sessions) are
    /// collected here for callers to gate on (D159/D163).
    static func scanBackward(anchor: Date,
                             sanityCapHours: Double = 48,
                             timeZone: TimeZone,
                             sessionsRoot: URL = AmbientStorage.sessionsRoot) -> BackwardScan {
        let anchorEpoch = anchor.timeIntervalSince1970
        let capEpoch = anchorEpoch - sanityCapHours * 3600
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            // A missing/unreadable sessions ROOT is "no records" (typed empty),
            // distinct from a session whose raw can't be read (a read failure).
            return BackwardScan(window: [], truncatedBeforeCoverage: false,
                                missingTimestampCount: 0, readFailureCount: 0, decodeFailureCount: 0)
        }
        var window: [TranscriptSegment] = []
        var truncated = false
        var missingTimestamp = 0
        var readFailures = 0
        var decodeFailures = 0
        for dir in dirs where dir.lastPathComponent.hasPrefix("ctx-") {
            let raw = dir.appendingPathComponent("transcripts/raw.jsonl")
            guard let attrs = try? fm.attributesOfItem(atPath: raw.path) else {
                readFailures += 1
                continue
            }
            let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let mod = attrs[.modificationDate] as? Date
            let decoded = cachedSessionSegments(rawPath: raw.path, modificationDate: mod, fileSize: fileSize)
            decodeFailures += decoded.decodeFailures
            for seg in decoded.segments {
                guard let at = seg.capturedAt else { missingTimestamp += 1; continue }
                if at < capEpoch {
                    truncated = true
                } else if at < anchorEpoch {
                    window.append(seg)
                }
            }
        }
        window.sort { ($0.capturedAt ?? 0) < ($1.capturedAt ?? 0) }
        return BackwardScan(window: window, truncatedBeforeCoverage: truncated,
                            missingTimestampCount: missingTimestamp, readFailureCount: readFailures,
                            decodeFailureCount: decodeFailures)
    }

    /// Delete rolling-buffer chunks older than `seconds` (default 6h) and prune
    /// emptied day directories. Sessions under sessions/ are intentionally NOT
    /// touched — they are kept until explicit deletion (design retention policy).
    static func pruneRolling(olderThan seconds: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-seconds)
        guard let dayDirs = try? fm.contentsOfDirectory(
            at: rollingRoot, includingPropertiesForKeys: nil) else { return }
        for dayDir in dayDirs {
            guard let chunks = try? fm.contentsOfDirectory(
                at: dayDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for chunk in chunks {
                let mod = (try? chunk.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let mod, mod < cutoff {
                    try? fm.removeItem(at: chunk)
                }
            }
            if let remaining = try? fm.contentsOfDirectory(atPath: dayDir.path), remaining.isEmpty {
                try? fm.removeItem(at: dayDir)
            }
        }
    }
}
