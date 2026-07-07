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

    /// The most recent session's kept transcript segments (chronological), for
    /// the Conversation Log UI. Returns (sessionID, segments capped at limit).
    static func latestSessionSegments(limit: Int) -> (String, [TranscriptSegment]) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil) else {
            return ("", [])
        }
        let sessionDirs = dirs
            .filter { $0.lastPathComponent.hasPrefix("ctx-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let latest = sessionDirs.last else { return ("", []) }
        let raw = latest.appendingPathComponent("transcripts/raw.jsonl")
        guard let data = try? Data(contentsOf: raw),
              let text = String(data: data, encoding: .utf8) else {
            return (latest.lastPathComponent, [])
        }
        let decoder = JSONDecoder()
        var segs: [TranscriptSegment] = []
        for line in text.split(separator: "\n") {
            if let d = line.data(using: .utf8),
               let seg = try? decoder.decode(TranscriptSegment.self, from: d) {
                segs.append(seg)
            }
        }
        if segs.count > limit { segs = Array(segs.suffix(limit)) }
        return (latest.lastPathComponent, segs)
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
        let decoder = JSONDecoder()
        var out: [TranscriptSegment] = []
        for dir in dirs where dir.lastPathComponent.hasPrefix("ctx-") {
            let raw = dir.appendingPathComponent("transcripts/raw.jsonl")
            // Skip sessions whose transcript was last written before this day
            // started: they cannot hold segments from it. A session that crossed
            // midnight keeps a newer mod time, so it is still read (safe side).
            let mod = (try? raw.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mod, mod < dayStart { continue }
            guard let data = try? Data(contentsOf: raw),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let seg = try? decoder.decode(TranscriptSegment.self, from: d),
                      let at = seg.capturedAt else { continue }
                if at >= startEpoch && at < endEpoch {
                    out.append(seg)
                }
            }
        }
        out.sort { ($0.capturedAt ?? 0) < ($1.capturedAt ?? 0) }
        return out
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
