import Foundation
import CryptoKit
import os

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
        /// #7: st_ctime bits — part of the decode-cache key so a same-size
        /// same-mtime content rewrite (new ctime) is re-decoded, not served stale.
        let ctimeBits: UInt64
        let segments: [TranscriptSegment]
        // D159: lines/files that could not be read or decoded (malformed JSONL,
        // unreadable bytes) — a source-completeness signal the caller fails
        // closed on. Cached alongside the segments so a re-read is consistent.
        let decodeFailures: Int
        /// Sidecar (ctime hygiene): lowercase-hex SHA-256 of the SETTLED raw bytes
        /// this cache entry decoded. Carried on the cache so a session-cache HIT
        /// returns the content identity without re-hashing (hash-once-at-decode).
        let rawSHA256: String
    }

    private struct DecodedSession {
        let segments: [TranscriptSegment]
        let decodeFailures: Int
        let readFailure: Bool
        let rawSHA256: String
        let rawByteCount: UInt64
        /// Fingerprint observed after these exact bytes decoded and settled.
        let modificationDate: Date?
        let ctimeBits: UInt64?
    }

    private static let logger = Logger(subsystem: "com.clawgate", category: "AmbientStorage")

    /// Sidecar (ctime hygiene): a per-`ctx-` durable, DERIVED (re-generatable) trust
    /// record that a file's undated-bound determinism was validated (mtime AND ctime
    /// <= next SID) for a specific content identity. On a later scan, if the CURRENT
    /// (sessionId, rawSHA256, rawByteCount, nextSessionId, policyCase) all match, the
    /// bound is trusted deterministic WITHOUT re-checking ctime — so a benign ctime
    /// flip (chmod/ACL repair, rsync/backup restore, xattr touch), which would
    /// otherwise turn the bound non-deterministic → open → refuse EVERY query
    /// (A3-05's own permission-repair recovery is exactly what triggers it), no
    /// longer revokes an already-validated bound across process restarts. Content
    /// bytes changing (new SHA) or the next-session identity changing forces a fresh
    /// mtime+ctime re-validation. The bound VALUES are always recomputed from current
    /// code (the persisted lower/upper are identity record only), so a future margin
    /// change never trusts a stale bound. Body-free, bounded metadata; NOT canonical
    /// data — it can be deleted and rebuilt.
    private struct ProvenanceBoundSidecar: Codable {
        let version: Int
        let sessionId: String
        let rawSHA256: String
        let rawByteCount: UInt64
        let lower: Double?
        let upper: Double?
        let nextSessionId: String?
        let policyCase: String   // "legacy20" | "overlap30" | "unknown63"
    }
    private static let sidecarVersion = 1
    private static let sidecarFileName = "provenance-bound-v1.json"

    private static var sessionSegmentsCache: [String: SessionSegmentsCache] = [:]
    private static var sessionSegmentsCacheOrder: [String] = []
    // D42: `segments(forDay:)` now runs off the main thread (D21) and can be
    // called concurrently for different days/roots, so the process-global cache
    // needs synchronization. The lock guards only the dictionary; the heavy
    // decode I/O runs OUTSIDE it (two-phase: check under lock, decode unlocked,
    // re-store under lock).
    private static let cacheLock = NSLock()

    /// A3-N01 memory-safety cap: bound each in-memory decode/snapshot cache to a
    /// fixed number of sessions (~1 year of heavy use at 2-3 sessions/day, ~8x the
    /// current ~124) so residency can't grow without limit over months of
    /// continuous use. Below the cap, behavior is byte-identical to unbounded;
    /// above it, the overflow re-decodes per scan — correct, just slower (the
    /// durable capturedAt scan-skip index, deferred A3-N01, is the real remedy for
    /// that cliff, NOT a larger cap). Eviction can never re-materialize P0-848: an
    /// evicted entry re-enters `buildSnapshot`, which consults `sidecarTrusts`
    /// before the ctime predicate, so determinism survives eviction exactly as it
    /// survives a restart.
    private static let cacheEntryCap = 1024

    /// Record a freshly-STORED key and FIFO-evict the oldest over `cacheEntryCap`.
    /// MUST be called under the cache's own lock. Under the full-scan access
    /// pattern (`canonicalSnapshots` touches every session each pass) LRU and FIFO
    /// are indistinguishable, so the simpler insertion-order eviction is used and
    /// the cache-HIT path stays a pure return with no per-hit reordering. `key` is
    /// appended only when NEW (an update keeps its original position — no duplicate
    /// order entries); `evict` removes a victim from the backing dictionary.
    private static func enforceCacheCap(_ key: String, isNew: Bool,
                                        order: inout [String], evict: (String) -> Void) {
        if isNew { order.append(key) }
        while order.count > cacheEntryCap { evict(order.removeFirst()) }
    }

    #if DEBUG
    private static let hookLock = NSLock()
    private static var _decodePauseHooks: [String: (String) -> Void] = [:]
    private static var _snapshotPauseHooks: [String: (String) -> Void] = [:]
    /// Test seam (D42): invoked after a file's bytes are read but before the decode
    /// is stored, so a test can rewrite the file mid-decode and assert the torn read
    /// is not cached and a newer entry is never rolled back. Keyed by the
    /// canonical exact raw path so different temp roots with identical session
    /// names cannot collide. Path-scoped (a REGISTRY, not one slot) so PARALLEL test classes
    /// registering hooks for DIFFERENT raws never clobber each other — a single
    /// global slot was last-writer-wins and could silently drop one class's hook,
    /// weakening its race coverage into a false pass. Lock-guarded against
    /// closure-pointer races.
    private static func canonicalTestRawPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func setDecodePauseHookForTesting(rawPath: String, _ hook: @escaping (String) -> Void) {
        hookLock.lock(); defer { hookLock.unlock() }
        _decodePauseHooks[canonicalTestRawPath(rawPath)] = hook
    }
    static func removeDecodePauseHookForTesting(rawPath: String) {
        hookLock.lock(); defer { hookLock.unlock() }
        _decodePauseHooks.removeValue(forKey: canonicalTestRawPath(rawPath))
    }
    static func setSnapshotPauseHookForTesting(rawPath: String, _ hook: @escaping (String) -> Void) {
        hookLock.lock(); defer { hookLock.unlock() }
        _snapshotPauseHooks[canonicalTestRawPath(rawPath)] = hook
    }
    static func removeSnapshotPauseHookForTesting(rawPath: String) {
        hookLock.lock(); defer { hookLock.unlock() }
        _snapshotPauseHooks.removeValue(forKey: canonicalTestRawPath(rawPath))
    }
    private static func snapshotPauseHook(forPath path: String) -> ((String) -> Void)? {
        hookLock.lock(); defer { hookLock.unlock() }
        return _snapshotPauseHooks[canonicalTestRawPath(path)]
    }
    private static func decodePauseHook(forPath path: String) -> ((String) -> Void)? {
        hookLock.lock(); defer { hookLock.unlock() }
        return _decodePauseHooks[canonicalTestRawPath(path)]
    }
    private static var _ctimeProvider: ((String) -> Date?)?
    private static var _fingerprintCtimeProvider: ((String) -> Date?)?
    /// Test seam (A3-25 ctime predicate): st_ctime (attribute-modification time)
    /// CANNOT be backdated by any file API — `FileManager.setAttributes` updates it
    /// to NOW — so an on-disk fixture cannot forge a consistent
    /// (mtime AND ctime <= next SID) file. This injects the ctime the determinism
    /// predicate reads, letting a test construct BOTH a genuinely-consistent file
    /// and a backdated-mtime (ctime-after-next) one. nil in production ⇒ the real
    /// `attributeModificationDate` is read.
    static var ctimeProviderForTesting: ((String) -> Date?)? {
        get { hookLock.lock(); defer { hookLock.unlock() }; return _ctimeProvider }
        set { hookLock.lock(); defer { hookLock.unlock() }; _ctimeProvider = newValue }
    }
    static var fingerprintCtimeProviderForTesting: ((String) -> Date?)? {
        get { hookLock.lock(); defer { hookLock.unlock() }; return _fingerprintCtimeProvider }
        set { hookLock.lock(); defer { hookLock.unlock() }; _fingerprintCtimeProvider = newValue }
    }
    /// Test seam (#4): number of ACTUAL decodes (cache misses). Reset per test.
    /// hookLock-guarded increment; read/reset on the (serial) test thread.
    static var decodeCountForTesting = 0
    /// Test seam (sidecar): force the sidecar write to fail without touching real
    /// permissions (chmod on a temp dir bumps its ctime and complicates cleanup),
    /// so a test can assert unwritable => raw bytes/mtime unchanged, still
    /// deterministic this launch, one degraded log, and NOT sticky next launch.
    static var sidecarWriteShouldFailForTesting = false
    #endif

    /// A3-25: st_ctime (attribute-modification time) of the raw file, via
    /// `URLResourceKey.attributeModificationDateKey` — NOT `creationDate`
    /// (birthtime). Used ONLY as a consistency predicate (ctime <= next SID) to
    /// reject a backdated mtime; never for coverage/relevance. Unobtainable ⇒ nil
    /// ⇒ the bound is treated as non-deterministic (fail-closed).
    private static func rawCtime(_ path: String) -> Date? {
        #if DEBUG
        if let provider = ctimeProviderForTesting { return provider(path) }
        #endif
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.attributeModificationDateKey]))?
            .attributeModificationDate
    }

    /// A3-25/#7: st_ctime bits for the EQUALITY/INVALIDATION fingerprint — a
    /// DISTINCT use and code path from `rawCtime` (the undated determinism
    /// predicate). This one has NO test seam: the fingerprint must reflect the REAL
    /// inode state so a same-size same-mtime content rewrite (whose ctime always
    /// advances and cannot be backdated) invalidates the cache. Unobtainable means
    /// nil: callers bypass both caches and use the settled content SHA instead of
    /// treating an unknown ctime as a stable zero value.
    private static func fingerprintCtimeBits(_ path: String) -> UInt64? {
        #if DEBUG
        if let provider = fingerprintCtimeProviderForTesting {
            return provider(path)?.timeIntervalSince1970.bitPattern
        }
        #endif
        let ctime = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.attributeModificationDateKey]))?
            .attributeModificationDate
        return ctime?.timeIntervalSince1970.bitPattern
    }

    /// Returns the decoded segments for one session's `raw.jsonl`, served from
    /// the shared cache when the (path, mod-date, size, ctime) fingerprint still
    /// matches. The decode happens outside the lock so a slow read never blocks
    /// a concurrent reader of a different session.
    private static func cachedSessionSegments(rawPath: String,
                                              modificationDate: Date?,
                                              fileSize: UInt64,
                                              ctimeBits: UInt64?) -> DecodedSession {
        cacheLock.lock()
        if let ctimeBits,
           let cached = sessionSegmentsCache[rawPath],
           cached.rawPath == rawPath,
           cached.modificationDate == modificationDate,
           cached.fileSize == fileSize,
           cached.ctimeBits == ctimeBits {
            // Only SUCCESSFUL reads are cached (A3-05), so a cache hit is never a
            // read failure. The cached SHA + size let a snapshot rebuild consult the
            // sidecar without re-hashing (hash-once-at-decode); both describe the same
            // settled bytes.
            let result = DecodedSession(
                segments: cached.segments, decodeFailures: cached.decodeFailures,
                readFailure: false, rawSHA256: cached.rawSHA256,
                rawByteCount: cached.fileSize, modificationDate: cached.modificationDate,
                ctimeBits: cached.ctimeBits)
            cacheLock.unlock()
            return result
        }
        cacheLock.unlock()

        let fm = FileManager.default
        // D42: read+decode, then re-stat. If the file changed under us (a torn
        // read — the (mod,size,ctime) key no longer describes what we decoded),
        // retry ONCE against the settled file; if it is STILL changing, fail closed
        // rather than cache/return a torn snapshot. Each attempt keys the cache by
        // the stat that its bytes actually correspond to. #7: ctime is part of the
        // settle key too, so a same-mtime+same-size CONCURRENT rewrite (its ctime
        // always advances and cannot be backdated) is detected — a (mod,size)-only
        // settle would roll back to the stale decode when a racing writer kept mtime
        // and size identical.
        var expectedMod = modificationDate
        var expectedSize = fileSize
        var expectedCtimeBits = ctimeBits
        for attempt in 0..<2 {
            // Heavy decode, off-lock.
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: rawPath)),
                  let text = String(data: data, encoding: .utf8) else {
                // A3-05: bytes cannot be read/UTF-8 decoded — a source read failure
                // (D159). Do NOT cache it (a chmod/ACL repair leaves mtime/size
                // unchanged, so a cached failure would refuse forever); the next
                // scan retries and recovers.
                return DecodedSession(segments: [], decodeFailures: 0, readFailure: true,
                                      rawSHA256: "", rawByteCount: 0,
                                      modificationDate: nil, ctimeBits: nil)
            }
            // Sidecar: SHA-256 of exactly THESE bytes. Computed inside the retry
            // loop so it always describes the bytes this iteration decoded; it only
            // escapes below once the (mod,size,ctime) settle-check passes, so the
            // cached SHA, the cached segments, and the settle-stat all come from ONE
            // read (a write between settle and a second read would give a SHA of
            // bytes nobody decoded).
            let sha = sha256Hex(data)
            #if DEBUG
            // Test seam (D42): on the FIRST attempt only, let a test rewrite the
            // file mid-decode to exercise the torn-read/rollback race. The registry
            // lookup is lock-guarded and returns only the hook for this canonical
            // exact raw path (so parallel classes never cross-fire).
            if attempt == 0 { decodePauseHook(forPath: rawPath)?(rawPath) }
            #endif
            #if DEBUG
            // Test seam (#4): counts an ACTUAL decode (cache miss). A stable
            // (same-fingerprint) file scanned repeatedly decodes exactly once.
            hookLock.lock(); decodeCountForTesting += 1; hookLock.unlock()
            #endif
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

            // D42: the post-decode re-stat MUST succeed. If it fails we cannot
            // verify the read settled — never fall into a nil==nil "stable" that
            // would healthily cache an unverified read (A3-02: a stat failure is a
            // source issue, not "no records").
            guard let postAttrs = try? fm.attributesOfItem(atPath: rawPath),
                  let postMod = postAttrs[.modificationDate] as? Date,
                  let postSize = (postAttrs[.size] as? NSNumber)?.uint64Value else {
                return DecodedSession(segments: [], decodeFailures: 0, readFailure: true,
                                      rawSHA256: "", rawByteCount: 0,
                                      modificationDate: nil, ctimeBits: nil)
            }
            let postCtimeBits = fingerprintCtimeBits(rawPath)
            var contentChangedWithoutCtime = false
            if postCtimeBits == nil, expectedCtimeBits == nil {
                // ctime is unavailable, so size+mtime cannot detect a forged
                // same-size/same-mtime rewrite. Re-read only in this rare path and
                // compare content identity before accepting the decode as settled.
                guard let verificationData = try? Data(contentsOf: URL(fileURLWithPath: rawPath)) else {
                    return DecodedSession(segments: [], decodeFailures: 0, readFailure: true,
                                          rawSHA256: "", rawByteCount: 0,
                                          modificationDate: nil, ctimeBits: nil)
                }
                contentChangedWithoutCtime = sha256Hex(verificationData) != sha
            }
            if postMod != expectedMod || postSize != expectedSize
                || postCtimeBits != expectedCtimeBits || contentChangedWithoutCtime {
                // Changed under us — retry once against the settled stat (ctime
                // catches a same-mtime+same-size concurrent rewrite).
                expectedMod = postMod
                expectedSize = postSize
                expectedCtimeBits = postCtimeBits
                continue
            }

            cacheLock.lock()
            // D42: never roll a NEWER published entry back to an older snapshot — a
            // concurrent reader of a freshly-rewritten file may have already stored
            // the new content while this (slower, older-snapshot) decode ran.
            let existing = sessionSegmentsCache[rawPath]
            let existingIsNewer: Bool = {
                guard let e = existing, let em = e.modificationDate, let m = expectedMod else { return false }
                if em != m { return em > m }
                guard let expectedCtimeBits else { return false }
                return e.ctimeBits > expectedCtimeBits
            }()
            if !existingIsNewer, let expectedCtimeBits {
                let isNew = existing == nil
                sessionSegmentsCache[rawPath] = SessionSegmentsCache(
                    rawPath: rawPath, modificationDate: expectedMod, fileSize: expectedSize,
                    ctimeBits: expectedCtimeBits, segments: segs, decodeFailures: decodeFailures,
                    rawSHA256: sha)
                enforceCacheCap(rawPath, isNew: isNew, order: &sessionSegmentsCacheOrder) {
                    sessionSegmentsCache.removeValue(forKey: $0)
                }
            }
            cacheLock.unlock()
            return DecodedSession(
                segments: segs, decodeFailures: decodeFailures, readFailure: false,
                rawSHA256: sha, rawByteCount: expectedSize,
                modificationDate: expectedMod, ctimeBits: expectedCtimeBits)
        }
        // Still changing after the bounded retry — fail closed.
        return DecodedSession(segments: [], decodeFailures: 0, readFailure: true,
                              rawSHA256: "", rawByteCount: 0,
                              modificationDate: nil, ctimeBits: nil)
    }

    /// Lowercase-hex SHA-256 of `data` (sidecar content identity / collision guard).
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
    /// touch the real Application Support tree. A3-25: delegates to the ONE
    /// canonical day reader so display and query never diverge (D17). Coverage is
    /// decided by `capturedAt`, never by file mtime.
    static func segments(forDay day: Date, timeZone: TimeZone, sessionsRoot: URL) -> [TranscriptSegment] {
        let out = segmentsForDayWithIssues(forDay: day, timeZone: timeZone, sessionsRoot: sessionsRoot).segments
        return out
    }

    /// D38/A3-25: a fingerprint of a day's on-disk state, composed from the
    /// canonical snapshots of ONLY the files RELEVANT to this day — those whose
    /// dated `[min,max] capturedAt` intersects the day, or that have a file issue,
    /// or whose undated bound intersects the day. Relevance is by capturedAt, not
    /// mtime, so today's active session (appending) does NOT churn a past day's
    /// fingerprint (D151), while a backfill with an in-day capturedAt DOES
    /// invalidate that day. The per-file fingerprint is (path, size, full
    /// sub-second mtime) so a same-second/same-size rewrite still changes it.
    static func dayFingerprint(forDay day: Date, timeZone: TimeZone,
                               sessionsRoot: URL = AmbientStorage.sessionsRoot) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayStart = cal.startOfDay(for: day)
        let startEpoch = dayStart.timeIntervalSince1970
        let endEpoch = (cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970
        let (snaps, rootUnreadable) = canonicalSnapshots(sessionsRoot: sessionsRoot)
        if rootUnreadable { return "root-unreadable" }  // distinct from "empty"
        var parts: [String] = []
        for s in snaps.sorted(by: { $0.path < $1.path }) {
            let datedIntersects = (s.minCapturedAt.map { $0 < endEpoch } ?? false)
                && (s.maxCapturedAt.map { $0 >= startEpoch } ?? false)
            let relevant = datedIntersects || s.hasFileIssue || s.undatedIntersects(startEpoch, endEpoch)
            if relevant { parts.append("\(s.path):\(s.fingerprint)") }
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: "|")
    }

    /// A3-02/A3-03: is this a "no such file/directory" (ENOENT) error — the only
    /// case treated as "no records" rather than a source issue. Checks the Cocoa
    /// code and any wrapped POSIX ENOENT (a permission/IO error is NOT this).
    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }

    // MARK: - A3-25 canonical file snapshot + capturedAt index

    /// Session start parsed from a `ctx-<ISO8601>` id (e.g.
    /// `ctx-2026-06-09T16-25-30Z`). Only the time `-` (which replaced `:` at
    /// creation) are restored; the date `-` are kept. Deterministic, no I/O.
    static func parseSessionStart(fromSessionID sid: String) -> Date? {
        guard sid.hasPrefix("ctx-") else { return nil }
        let stamp = String(sid.dropFirst(4))
        guard let t = stamp.firstIndex(of: "T") else { return nil }
        let datePart = stamp[..<t]
        let timePart = stamp[stamp.index(after: t)...].replacingOccurrences(of: "-", with: ":")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.date(from: "\(datePart)T\(timePart)")
    }

    /// A3-25: the CONSERVATIVE fail-closed fallback margin (60s initial no-overlap
    /// chunk + 3s = 63s) used when a file has no preset.json, an unknown
    /// chunkSeconds, or a decode failure. A wider margin only ever refuses slightly
    /// more (undated is a refuse bound, not an inclusion), never less.
    static let conservativeUndatedLowerMarginSeconds: Double = 63

    /// A3-25: the undated lower-bound margin — a VERSIONED HISTORICAL mapping
    /// (ruling (b)-versioned, FINAL — no further revision). Derived from git
    /// history, NOT an assumption: commit 8cf10b25 introduced `chunkSeconds:30 +
    /// overlapSeconds:3` in ONE diff and no production `AmbientCaptureManager(` call
    /// has changed those args since, so 30↔(30+3)=33s is proven; `chunkSeconds:20`
    /// predated the overlap mechanism (b1d2b187), so 20↔20s. ONLY these two verified
    /// values map to a real margin — a missing preset, an unknown chunkSeconds, or a
    /// decode failure falls back to the conservative 63s. Generalizing "+3 for any
    /// chunkSeconds" is FORBIDDEN: only the two history-verified values plus the
    /// fail-closed default. (A future D35 versioned capture-policy would persist the
    /// real per-file chunk+overlap and supersede this fixed mapping.)
    private static func undatedMarginAndPolicy(sessionDir: URL) -> (margin: Double, policyCase: String) {
        struct Meta: Decodable { let chunkSeconds: Int }
        let preset = sessionDir.appendingPathComponent("preset.json")
        guard let data = try? Data(contentsOf: preset),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            return (conservativeUndatedLowerMarginSeconds, "unknown63")
        }
        switch meta.chunkSeconds {
        case 30: return (33, "overlap30")   // 8cf10b25: chunkSeconds:30 + overlapSeconds:3
        case 20: return (20, "legacy20")    // b1d2b187..8cf10b25: chunkSeconds:20, no overlap
        default: return (conservativeUndatedLowerMarginSeconds, "unknown63")  // unknown -> fail-closed
        }
    }

    // MARK: - Provenance-bound sidecar (ctime hygiene)

    /// Read + parse the per-session trust record. Missing (normal first run) OR
    /// corrupt ⇒ nil; corrupt is IGNORED, never quarantined (derived, re-generatable
    /// data — the caller rebuilds it).
    private static func readSidecar(sessionDir: URL) -> ProvenanceBoundSidecar? {
        guard let data = try? Data(contentsOf: sessionDir.appendingPathComponent(sidecarFileName)) else {
            return nil
        }
        return try? JSONDecoder().decode(ProvenanceBoundSidecar.self, from: data)
    }

    /// Does the CURRENT content+identity match the persisted trust record? ALL of
    /// (version, sessionId, rawSHA256, rawByteCount, nextSessionId, policyCase) must
    /// match — then the bound was already validated deterministic (mtime AND ctime <=
    /// next SID) for THIS exact state, so its determinism holds regardless of the
    /// current ctime.
    private static func sidecarTrusts(sessionDir: URL, sessionId: String, rawSHA256: String,
                                      rawByteCount: UInt64, nextSessionId: String?,
                                      policyCase: String) -> Bool {
        guard let s = readSidecar(sessionDir: sessionDir), s.version == sidecarVersion else { return false }
        return s.sessionId == sessionId && s.rawSHA256 == rawSHA256 && s.rawByteCount == rawByteCount
            && s.nextSessionId == nextSessionId && s.policyCase == policyCase
    }

    /// Atomically persist the validated trust record: UUID temp (0600) → POSIX
    /// rename(2) (one atomic overwrite) into the session dir (0700), no backup. A
    /// write failure is NON-STICKY: it logs a degraded diagnostic (os.Logger ONLY —
    /// this is an internal optimization cache, not session data; the current launch
    /// still works via live ctime validation, i.e. the pre-sidecar baseline) and
    /// leaves the raw file untouched.
    private static func writeSidecar(_ record: ProvenanceBoundSidecar, sessionDir: URL) {
        #if DEBUG
        if sidecarWriteShouldFailForTesting {
            logger.warning("provenance sidecar write forced-fail (test seam) for \(record.sessionId, privacy: .public)")
            return
        }
        #endif
        let fm = FileManager.default
        let dest = sessionDir.appendingPathComponent(sidecarFileName)
        let tmp = sessionDir.appendingPathComponent(".provenance-bound-\(UUID().uuidString).tmp")
        do {
            try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionDir.path)
            let data = try JSONEncoder().encode(record)
            guard fm.createFile(atPath: tmp.path, contents: data,
                                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if rename(tmp.path, dest.path) != 0 {
                try? fm.removeItem(at: tmp)
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            logger.warning("provenance sidecar write failed (degraded, non-sticky): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove a stale record. Called when a rebuild found the bound NON-deterministic,
    /// so no record may survive on disk that a future scan could match (write-once
    /// discipline: after `buildSnapshot`, the sidecar is either freshly-written-matching
    /// or absent — never a stale survivor).
    private static func removeSidecar(sessionDir: URL) {
        try? FileManager.default.removeItem(at: sessionDir.appendingPathComponent(sidecarFileName))
    }

    /// A3-25: a canonical per-file snapshot. Every retrieval path (automatic
    /// scan, explicit day read, display, day fingerprint) is derived from the
    /// SAME snapshot set, so display and query never diverge (D17). In-memory
    /// only — rebuilt on process start (a restart yields the same result). mtime
    /// and ctime are used ONLY to invalidate a stale snapshot (the equality
    /// fingerprint) and as a consistency check, never to decide coverage/relevance
    /// (D153/A3-N01).
    struct CanonicalSnapshot {
        let path: String
        let size: UInt64
        let mtimeBits: UInt64
        /// st_ctime (attribute-modification time) — folded into `fingerprint` for
        /// EQUALITY/INVALIDATION only (#7/D42 point2): a same-size same-mtime content
        /// rewrite advances ctime (and ctime cannot be backdated), so the stale
        /// decode is not served. This is a SEPARATE use and code path from the
        /// undated determinism predicate's `rawCtime` (ctime<=next SID); the two must
        /// never be conflated. A benign ctime flip (chmod/rsync) costs at most one
        /// spurious re-decode here, never a refusal.
        let ctimeBits: UInt64?
        /// Content identity used when ctime is unavailable and for sidecar trust.
        let rawSHA256: String
        /// Dated segments (capturedAt != nil), sorted by capturedAt.
        let dated: [TranscriptSegment]
        let minCapturedAt: Double?
        let maxCapturedAt: Double?
        let decodeFailures: Int
        let readFailure: Bool
        /// Undated (capturedAt == nil) records: count + the file-level provenance
        /// bound `[lower, upper)` they are attributable to (A3-25 — NOT per-line;
        /// chunk append order is not FIFO-guaranteed). A nil endpoint is open. A
        /// non-deterministic bound is treated as open on both sides (unknown ⇒
        /// intersects any window, fail-closed).
        let undatedCount: Int
        let undatedLower: Double?
        let undatedUpper: Double?
        let undatedDeterministic: Bool
        /// Non-raw dependencies that can change an undated bound while the raw
        /// fingerprint remains identical.
        let undatedNextSessionId: String?
        let undatedPolicyCase: String?

        /// Does this file's undated bound intersect `[wLo, wHi)`?
        func undatedIntersects(_ wLo: Double, _ wHi: Double) -> Bool {
            guard undatedCount > 0 else { return false }
            let lo = undatedDeterministic ? undatedLower : nil
            let hi = undatedDeterministic ? undatedUpper : nil
            let aboveLo = (hi == nil) || (hi! > wLo)
            let belowHi = (lo == nil) || (lo! < wHi)
            return aboveLo && belowHi
        }
        var hasFileIssue: Bool { readFailure || decodeFailures > 0 }
        /// D42/D38/#7: two snapshots describe the same bytes iff size + mtime + ctime
        /// match. ctime closes the same-size/same-mtime content-rewrite gap; mtime
        /// alone (or size+mtime) could collide on a forged/frozen mtime.
        var fingerprint: String {
            let identity = ctimeBits.map(String.init) ?? "sha256:\(rawSHA256)"
            return "\(size):\(mtimeBits):\(identity)"
        }
    }

    private static var canonicalIndex: [String: CanonicalSnapshot] = [:]
    private static var canonicalIndexOrder: [String] = []
    private static let indexLock = NSLock()

    /// A3-25: the current canonical snapshots for every `ctx-` session under
    /// `sessionsRoot`, plus whether the root itself was unreadable (A3-02: an
    /// ABSENT root ⇒ false; an EXISTING but unreadable root ⇒ true). Reuses a
    /// cached snapshot while its (size, mtime, ctime) fingerprint is unchanged (D42
    /// /#7: canonical fingerprint, not mtime alone — ctime catches a same-size
    /// same-mtime content rewrite); a changed file is re-decoded and its undated
    /// bound recomputed. No file mtime filters which files are read.
    static func canonicalSnapshots(sessionsRoot: URL) -> (snapshots: [CanonicalSnapshot], rootUnreadable: Bool) {
        let fm = FileManager.default
        let dirs: [URL]
        do {
            dirs = try fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)
        } catch {
            return ([], !isNoSuchFileError(error))
        }
        let ctxDirs = dirs.filter { $0.lastPathComponent.hasPrefix("ctx-") }
        // Sorted (sessionId, start) for each file's "next session" undated upper —
        // the id is needed for the sidecar's next-session identity (sidecar).
        let sortedSessions: [(id: String, start: Double)] = ctxDirs
            .compactMap { d in
                parseSessionStart(fromSessionID: d.lastPathComponent)
                    .map { (id: d.lastPathComponent, start: $0.timeIntervalSince1970) }
            }
            .sorted { $0.start < $1.start }
        var out: [CanonicalSnapshot] = []
        for dir in ctxDirs {
            let raw = dir.appendingPathComponent("transcripts/raw.jsonl")
            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try fm.attributesOfItem(atPath: raw.path)
            } catch {
                // A3-03/D177: a raw that does not exist yet is a fresh session
                // (skip, 0 records); an existing raw that cannot be stat'd is a
                // read-failure snapshot.
                if isNoSuchFileError(error) { continue }
                out.append(CanonicalSnapshot(
                    path: raw.path, size: 0, mtimeBits: 0, ctimeBits: nil, rawSHA256: "",
                    dated: [], minCapturedAt: nil,
                    maxCapturedAt: nil, decodeFailures: 0, readFailure: true,
                    undatedCount: 0, undatedLower: nil, undatedUpper: nil,
                    undatedDeterministic: false, undatedNextSessionId: nil,
                    undatedPolicyCase: nil))
                continue
            }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = attrs[.modificationDate] as? Date
            let mtimeBits = (mtime?.timeIntervalSince1970 ?? 0).bitPattern
            // #7: ctime completes the equality fingerprint — a same-size same-mtime
            // content rewrite advances ctime, so its snapshot is rebuilt not reused.
            let ctimeBits = fingerprintCtimeBits(raw.path)
            indexLock.lock()
            if let ctimeBits, let cached = canonicalIndex[raw.path], cached.size == size,
               cached.mtimeBits == mtimeBits, cached.ctimeBits == ctimeBits {
                let provenanceStillMatches: Bool
                if cached.undatedCount == 0 {
                    provenanceStillMatches = true
                } else if let start = parseSessionStart(fromSessionID: dir.lastPathComponent)?.timeIntervalSince1970 {
                    let nextId = sortedSessions.first { $0.start > start }?.id
                    let policyCase = undatedMarginAndPolicy(sessionDir: dir).policyCase
                    provenanceStillMatches = cached.undatedNextSessionId == nextId
                        && cached.undatedPolicyCase == policyCase
                } else {
                    provenanceStillMatches = cached.undatedNextSessionId == nil
                        && cached.undatedPolicyCase == nil
                }
                if provenanceStillMatches {
                    indexLock.unlock()
                    out.append(cached)
                    continue
                }
                indexLock.unlock()
            } else {
                indexLock.unlock()
            }
            let snap = buildSnapshot(sessionDir: dir, rawPath: raw.path, size: size, mtime: mtime,
                                     ctimeBits: ctimeBits, sortedSessions: sortedSessions)
            indexLock.lock()
            // D42: do not roll a NEWER published fingerprint back to an older one —
            // compare the SETTLED fingerprint a concurrent reader may have stored.
            let existingIsNewer: Bool = {
                guard let existing = canonicalIndex[raw.path] else { return false }
                if existing.mtimeBits != snap.mtimeBits { return existing.mtimeBits > snap.mtimeBits }
                guard let existingCtime = existing.ctimeBits, let snapCtime = snap.ctimeBits else { return false }
                return existingCtime > snapCtime
            }()
            if existingIsNewer {
                let existing = canonicalIndex[raw.path]!
                out.append(existing)
            } else {
                // A3-05: never cache a read-failure snapshot — a chmod/ACL repair
                // leaves size/mtime unchanged, so a cached failure would refuse
                // forever. Return it, but re-read it next scan.
                if !snap.readFailure, snap.ctimeBits != nil {
                    let isNew = canonicalIndex[raw.path] == nil
                    canonicalIndex[raw.path] = snap
                    enforceCacheCap(raw.path, isNew: isNew, order: &canonicalIndexOrder) {
                        canonicalIndex.removeValue(forKey: $0)
                    }
                }
                out.append(snap)
            }
            indexLock.unlock()
        }
        return (out, false)
    }

    /// Build a canonical snapshot for one raw file: decode (D42-safe via the
    /// bounded-retry `cachedSessionSegments`), partition dated/undated, compute
    /// capturedAt min/max, and derive the file-level undated provenance bound.
    private static func buildSnapshot(sessionDir: URL, rawPath: String, size: UInt64,
                                      mtime: Date?, ctimeBits: UInt64?,
                                      sortedSessions: [(id: String, start: Double)]) -> CanonicalSnapshot {
        let decoded = cachedSessionSegments(rawPath: rawPath, modificationDate: mtime,
                                            fileSize: size, ctimeBits: ctimeBits)
        #if DEBUG
        snapshotPauseHook(forPath: rawPath)?(rawPath)
        #endif
        // The decode helper returns the stat that settled THESE exact bytes. Do
        // not re-stat here: a rewrite in that gap would label old decoded bytes
        // with a newer fingerprint and poison both caches.
        let settledSize = decoded.rawByteCount
        let settledMtime = decoded.modificationDate?.timeIntervalSince1970
            ?? (mtime?.timeIntervalSince1970 ?? 0)
        let settledCtimeBits = decoded.ctimeBits

        var dated: [TranscriptSegment] = []
        var undatedCount = 0
        for seg in decoded.segments {
            if seg.capturedAt == nil { undatedCount += 1 } else { dated.append(seg) }
        }
        dated.sort { ($0.capturedAt ?? 0) < ($1.capturedAt ?? 0) }
        let epochs = dated.compactMap(\.capturedAt)

        // A3-25 undated provenance bound (file-level). lower = sessionStart -
        // policy margin; upper = the NEXT session's start. Deterministic only when
        // the SID parses, a next session exists, and BOTH mtime AND ctime settle
        // at/before the next SID. mtime alone is forgeable (setAttributes backdates
        // it); ctime (attribute-mod time) is not, so ctime <= next rejects a
        // backdated-mtime file. An unobtainable ctime, or either time after next,
        // is a consistency failure (unknown/open bound, fail-closed) — NOT an
        // exclude reason, and never coverage.
        var undatedLower: Double?
        var undatedUpper: Double?
        var deterministic = false
        var undatedNextSessionId: String?
        var undatedPolicyCase: String?
        if undatedCount > 0, let start = parseSessionStart(fromSessionID: sessionDir.lastPathComponent)?.timeIntervalSince1970 {
            let nextPair = sortedSessions.first { $0.start > start }
            let (margin, policyCase) = undatedMarginAndPolicy(sessionDir: sessionDir)
            undatedNextSessionId = nextPair?.id
            undatedPolicyCase = policyCase
            undatedLower = start - margin
            undatedUpper = nextPair?.start
            if let nextPair {
                let sessionId = sessionDir.lastPathComponent
                // Sidecar (ctime hygiene): if the persisted trust record matches the
                // CURRENT content+identity, this bound was already validated
                // deterministic (mtime AND ctime <= next SID) — TRUST it without
                // re-checking ctime, so a benign ctime flip (chmod/rsync/xattr, even
                // across app restarts) can't revoke it. Consulted ONLY here, on
                // snapshot REBUILD (a canonicalIndex hit skips buildSnapshot, so an
                // unchanged fingerprint keeps the prior determinism). Bound VALUES are
                // recomputed above; the sidecar gates determinism-trust only.
                if sidecarTrusts(sessionDir: sessionDir, sessionId: sessionId,
                                 rawSHA256: decoded.rawSHA256, rawByteCount: decoded.rawByteCount,
                                 nextSessionId: nextPair.id, policyCase: policyCase) {
                    deterministic = true
                } else {
                    let mtimeOK = settledMtime <= nextPair.start
                    let ctimeOK = (rawCtime(rawPath)?.timeIntervalSince1970).map { $0 <= nextPair.start } ?? false
                    deterministic = mtimeOK && ctimeOK
                    // Write-once discipline: after rebuild the on-disk sidecar is either
                    // freshly-written-matching (deterministic) or absent (else) — never
                    // a stale survivor a future scan could match.
                    if deterministic {
                        writeSidecar(ProvenanceBoundSidecar(
                            version: sidecarVersion, sessionId: sessionId, rawSHA256: decoded.rawSHA256,
                            rawByteCount: decoded.rawByteCount, lower: undatedLower, upper: undatedUpper,
                            nextSessionId: nextPair.id, policyCase: policyCase), sessionDir: sessionDir)
                    } else {
                        removeSidecar(sessionDir: sessionDir)
                    }
                }
            }
        }
        return CanonicalSnapshot(
            path: rawPath, size: settledSize, mtimeBits: settledMtime.bitPattern,
            ctimeBits: settledCtimeBits, rawSHA256: decoded.rawSHA256, dated: dated,
            minCapturedAt: epochs.min(), maxCapturedAt: epochs.max(),
            decodeFailures: decoded.decodeFailures, readFailure: decoded.readFailure,
            undatedCount: undatedCount, undatedLower: undatedLower,
            undatedUpper: undatedUpper, undatedDeterministic: deterministic,
            undatedNextSessionId: undatedNextSessionId,
            undatedPolicyCase: undatedPolicyCase)
    }

    #if DEBUG
    /// Test seam: clears the in-memory canonical index so a test can prove that a
    /// rebuild (as after a restart) yields the same result.
    static func clearCanonicalIndexForTesting() {
        indexLock.lock(); canonicalIndex.removeAll(); canonicalIndexOrder.removeAll(); indexLock.unlock()
    }
    #endif

    /// D159/D163 (A3-01/02/03): typed source-completeness signals collected in one
    /// pass over the sessions, shared by the automatic (scanBackward) and the
    /// explicit (segmentsForDayWithIssues) retrieval paths.
    struct SourceIssues: Equatable {
        /// Real utterances whose `capturedAt` is missing (undated) — the anchor
        /// cutoff cannot be verified against them (D163).
        var missingTimestampCount = 0
        /// Existing raw files that could not be stat/read/UTF-8-decoded (D159).
        /// A raw file that does NOT exist yet (a fresh session before its first
        /// kept segment) is NOT counted — that is a normal 0-record state (D177).
        var readFailureCount = 0
        /// Malformed JSONL lines inside an otherwise-readable raw (D159).
        var decodeFailureCount = 0
        /// The sessions ROOT exists but its listing failed (EACCES/IO). An ABSENT
        /// root is "no records" and is NOT flagged (A3-02).
        var rootUnreadable = false

        var hasIssue: Bool {
            missingTimestampCount > 0 || readFailureCount > 0 || decodeFailureCount > 0 || rootUnreadable
        }
    }

    /// Iterates every `ctx-` session under `sessionsRoot` in one pass, decoding
    /// each raw transcript and collecting typed source issues, and hands each
    /// session's decoded segments to `handle`. Root/raw semantics (A3-02/A3-03):
    /// an ABSENT root is empty with no issue; an existing-but-unreadable root is
    /// `rootUnreadable`; a raw file that does not exist yet is skipped (0 records,
    /// not a failure); an existing raw that fails to stat/read/decode is a source
    /// issue. No file mtime is used to filter which sessions are read (D153).
    /// `includeSession` decides, from a session's mtime, whether it is relevant to
    /// the caller's window (the day read skips sessions written before the day, so
    /// an unrelated broken/old session does not refuse an unrelated query; the
    /// backward scan includes everything). A session filtered out is neither
    /// decoded nor counted as an issue.
    /// A3-25: derive typed source issues for a query window `[wLo, wHi)` from the
    /// canonical snapshots. Undated records are counted as an issue ONLY when the
    /// file's provenance bound intersects the window (P0: the real corpus has 848
    /// undated lines; a GLOBAL count would refuse every query — an undated file
    /// whose bound cannot touch the window is not a reason to refuse).
    private static func sourceIssues(_ snaps: [CanonicalSnapshot], rootUnreadable: Bool,
                                     window: (Double, Double)) -> SourceIssues {
        var issues = SourceIssues()
        issues.rootUnreadable = rootUnreadable
        for s in snaps {
            if s.readFailure { issues.readFailureCount += 1 }
            issues.decodeFailureCount += s.decodeFailures
            if s.undatedIntersects(window.0, window.1) { issues.missingTimestampCount += s.undatedCount }
        }
        return issues
    }

    /// Result of a backward scan — the in-window segments plus typed
    /// completeness signals, all derived from the canonical snapshots (A3-25).
    struct BackwardScan {
        /// Segments captured in `[anchor - cap, anchor)`, ordered by capturedAt.
        let window: [TranscriptSegment]
        /// D153: true when retained data OLDER than the cap exists — the
        /// automatic window may have cut off the start of the conversation.
        /// Determined from `capturedAt` (never file mtime).
        let truncatedBeforeCoverage: Bool
        /// D159/D163: typed source-completeness issues found during the scan.
        let issues: SourceIssues

        var hasSourceIssue: Bool { issues.hasIssue }
    }

    /// D153/A3-25: the automatic-scope retrieval source — derived from the
    /// canonical snapshots (partitioned by `capturedAt`, never file mtime).
    /// Returns the in-window segments, `truncatedBeforeCoverage` (older retained
    /// data exists), and typed source issues (undated intersecting the window).
    static func scanBackward(anchor: Date,
                             sanityCapHours: Double = 48,
                             timeZone: TimeZone,
                             sessionsRoot: URL = AmbientStorage.sessionsRoot) -> BackwardScan {
        let anchorEpoch = anchor.timeIntervalSince1970
        let capEpoch = anchorEpoch - sanityCapHours * 3600
        let (snaps, rootUnreadable) = canonicalSnapshots(sessionsRoot: sessionsRoot)
        var window: [TranscriptSegment] = []
        var truncated = false
        for s in snaps {
            for seg in s.dated {
                guard let at = seg.capturedAt else { continue }
                if at < capEpoch { truncated = true }
                else if at < anchorEpoch { window.append(seg) }
            }
            // A3-25/D153: undated records whose provenance bound lies ENTIRELY older
            // than the cap ARE retained data older than coverage — set the
            // truncated flag. This is the exact below-side complement of
            // `undatedIntersects`: only a DETERMINISTIC bound with `upper <= cap`
            // qualifies. An intersecting or unknown/open bound is a source issue
            // instead (sourceIssues), never a silent truncation signal — so no
            // deterministic bound falls into both or neither, and an unknown bound
            // never asserts older-data evidence that does not exist.
            if s.undatedCount > 0, s.undatedDeterministic,
               let upper = s.undatedUpper, upper <= capEpoch {
                truncated = true
            }
        }
        window.sort { ($0.capturedAt ?? 0) < ($1.capturedAt ?? 0) }
        return BackwardScan(window: window, truncatedBeforeCoverage: truncated,
                            issues: sourceIssues(snaps, rootUnreadable: rootUnreadable,
                                                 window: (capEpoch, anchorEpoch)))
    }

    /// D159/D163/A3-25 explicit path (A3-01): the day's segments plus typed source
    /// issues, derived from the SAME canonical snapshots as display/scan so an
    /// explicit scene selection fails closed on a broken/undated source and never
    /// diverges from the display (D17).
    struct DayRead { let segments: [TranscriptSegment]; let issues: SourceIssues }
    static func segmentsForDayWithIssues(forDay day: Date, timeZone: TimeZone,
                                         sessionsRoot: URL = AmbientStorage.sessionsRoot) -> DayRead {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayStart = cal.startOfDay(for: day)
        let startEpoch = dayStart.timeIntervalSince1970
        let endEpoch = (cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970
        let (snaps, rootUnreadable) = canonicalSnapshots(sessionsRoot: sessionsRoot)
        var out: [TranscriptSegment] = []
        for s in snaps {
            for seg in s.dated {
                guard let at = seg.capturedAt else { continue }
                if at >= startEpoch && at < endEpoch { out.append(seg) }
            }
        }
        out.sort { ($0.capturedAt ?? 0) < ($1.capturedAt ?? 0) }
        return DayRead(segments: out, issues: sourceIssues(snaps, rootUnreadable: rootUnreadable,
                                                           window: (startEpoch, endEpoch)))
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
