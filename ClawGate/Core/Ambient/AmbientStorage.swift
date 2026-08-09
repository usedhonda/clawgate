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
                                              fileSize: UInt64) -> [TranscriptSegment] {
        cacheLock.lock()
        if let cached = sessionSegmentsCache[rawPath],
           cached.rawPath == rawPath,
           cached.modificationDate == modificationDate,
           cached.fileSize == fileSize {
            let segs = cached.segments
            cacheLock.unlock()
            return segs
        }
        cacheLock.unlock()

        // Heavy decode, off-lock.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: rawPath)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var segs: [TranscriptSegment] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let seg = try? decoder.decode(TranscriptSegment.self, from: d) else { continue }
            segs.append(seg)
        }

        cacheLock.lock()
        // Another thread may have populated an equal entry meanwhile; the
        // (mod,size) fingerprint decides validity, so overwriting is safe.
        sessionSegmentsCache[rawPath] = SessionSegmentsCache(
            rawPath: rawPath, modificationDate: modificationDate, fileSize: fileSize, segments: segs)
        cacheLock.unlock()
        return segs
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
            let decoded = cachedSessionSegments(rawPath: raw.path, modificationDate: mod, fileSize: fileSize)
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

    /// D20: the automatic-scope retrieval source. Returns ALL segments in the
    /// window `[anchor - sanityCapHours, anchor)`, crossing calendar days — the
    /// calendar day is a display/navigation boundary, not a context boundary.
    /// Retrieval does NOT stop at a time gap: a lunch gap must not permanently
    /// drop the morning, and a mere gap is not a scene change. Deciding which
    /// leading run to exclude is the MODEL's job (the shipped automaticBackward
    /// suffix-trim contract); retrieval only supplies the cross-day ordered
    /// history it trims from.
    ///
    /// The only bound is the sanity cap (default 48h, or the storage retention
    /// window, whichever is smaller — callers pass the smaller). `reachedCap` is
    /// the client-side "history incomplete" signal — callers fail closed on it
    /// (D16) rather than letting the model assume it saw the whole conversation.
    /// It is conservatively true whenever ANY retained data older than the cap
    /// exists: the storage layer cannot prove that a time gap is a semantic
    /// conversation boundary (that trimming is the model's job), so a gap inside
    /// the window does NOT make retrieval complete — the conversation the user
    /// is asking about may extend into what the cap truncated. Retrieval is
    /// complete only when there is no older retained data at all. No new
    /// wire/prefix field is added.
    static func segmentsBackwardFromAnchor(anchor: Date,
                                           sanityCapHours: Double = 48,
                                           timeZone: TimeZone,
                                           sessionsRoot: URL) -> (segments: [TranscriptSegment], reachedCap: Bool) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let anchorEpoch = anchor.timeIntervalSince1970
        let capEpoch = anchorEpoch - sanityCapHours * 3600
        let anchorDay = cal.startOfDay(for: anchor)
        // The 48h window spans up to three calendar days; scan one extra day
        // back so we can also see whether data continues just before the cap.
        var candidates: [TranscriptSegment] = []
        for offset in [-3, -2, -1, 0] {
            guard let d = cal.date(byAdding: .day, value: offset, to: anchorDay) else { continue }
            candidates += segments(forDay: d, timeZone: timeZone, sessionsRoot: sessionsRoot)
        }
        let sorted = candidates.sorted { ($0.capturedAt ?? 0) < ($1.capturedAt ?? 0) }
        let window = sorted.filter { seg in
            guard let at = seg.capturedAt else { return false }
            return at >= capEpoch && at < anchorEpoch
        }
        guard !window.isEmpty else { return ([], false) }

        // Conservative incompleteness: any scanned segment older than the cap
        // proves retained history the window truncated.
        let hasPreCapSegment = sorted.contains { seg in
            guard let at = seg.capturedAt else { return false }
            return at < capEpoch
        }
        // Cheap no-decode extension beyond the 3-day scan: a non-empty session
        // file last written before the cap can only hold pre-cap data, so its
        // presence proves older retained history exists even when it falls
        // outside the scanned days.
        let reachedCap = hasPreCapSegment || sessionFileWrittenBefore(capEpoch, sessionsRoot: sessionsRoot)
        return (window, reachedCap)
    }

    /// No-decode check: does any session's `raw.jsonl` have a last-write time
    /// before `epoch` (and non-empty content)? Such a file can only hold
    /// segments captured at/before that write, i.e. entirely older than `epoch`.
    private static func sessionFileWrittenBefore(_ epoch: Double, sessionsRoot: URL) -> Bool {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return false
        }
        for dir in dirs where dir.lastPathComponent.hasPrefix("ctx-") {
            let raw = dir.appendingPathComponent("transcripts/raw.jsonl")
            guard let attrs = try? fm.attributesOfItem(atPath: raw.path),
                  let mod = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value, size > 0 else { continue }
            if mod < epoch { return true }
        }
        return false
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
