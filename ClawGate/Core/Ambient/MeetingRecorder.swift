import Foundation

/// What a meeting was, so minutes can be made of it afterwards.
///
/// The transcript itself is never copied here: it already lives in the
/// session's `raw.jsonl`, and a second copy would drift from it. A meeting
/// record is the time range plus who was there.
struct MeetingRecord: Codable, Equatable {
    var id: String
    /// "meet" (Chrome reported a call) or "manual" (started from the app).
    var source: String
    var startedAt: Double
    var endedAt: Double?
    /// The zone the Mac was in during the meeting; labels are read back in it
    /// even if the owner has since travelled.
    var timeZone: String
    var title: String?
    var conferenceCode: String?
    /// Everyone whose tile was seen at any point, not a snapshot of one moment:
    /// a start-of-call snapshot misses late joiners and an end-of-call one
    /// misses whoever left early.
    var participants: [String]
    /// none | pending | ready | failed
    var minutesState: String
    var minutesError: String?
    /// Retrospective calendar association, selected by the owner. Optional so
    /// existing on-disk Meet records remain readable.
    var calendarEventID: String? = nil
    var calendarID: String? = nil
    var calendarEventStart: Double? = nil
    var calendarEventEnd: Double? = nil
    var boundaryEvidence: String? = nil
    var mergedIntoMeetingID: String? = nil
    /// Actual last Meet heartbeat, independent of metadata writes to meeting.json.
    var lastHeartbeatAt: Double? = nil

    var isOpen: Bool { endedAt == nil }

    func duration(now: Double) -> Double { max(0, (endedAt ?? now) - startedAt) }
}

/// Metadata the Chrome extension reports alongside the call heartbeat.
struct MeetingHeartbeatMeta: Equatable {
    var code: String?
    var title: String?
    var roster: [String]

    /// Meet titles its tab "Meet - <name>" (or just the code when the call was
    /// not created from a calendar entry). Anything that is only the code is
    /// no title at all.
    static func cleanTitle(_ raw: String?, code: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        for prefix in ["Meet - ", "Meet – ", "Meet — ", "Google Meet - "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        for suffix in [" - Google Meet", " – Google Meet"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == code || t == "Meet" { return nil }
        return t
    }
}

/// Turns the Meet call heartbeat into a durable meeting record.
///
/// Start and end are edges of the heartbeat, which the controller already
/// debounces (a call ends when the heartbeat has been silent for its TTL), so
/// this type only has to remember what it saw and when.
final class MeetingRecorder {
    /// A meeting's transcript runs a little past the last heartbeat so the
    /// closing words are not cut off. It never runs into the next meeting.
    static let tailSeconds: Double = 60

    private(set) var current: MeetingRecord?
    private var lastSeen: Double = 0
    private let store: MeetingStore
    private let log: (String) -> Void

    init(store: MeetingStore = MeetingStore(), log: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.log = log
        // A meeting left open by a crash or an app restart would otherwise stay
        // open forever, and its transcript range would keep growing.
        for closed in store.closeOpenMeetings() {
            log("meeting closed on startup \(closed.id)")
        }
    }

    enum Event: Equatable {
        case started(MeetingRecord)
        case ended(MeetingRecord)
        case none
    }

    /// Feed one heartbeat. Returns the lifecycle edge it produced, if any.
    @discardableResult
    func heartbeat(inCall: Bool, meta: MeetingHeartbeatMeta? = nil,
                   source: String = "meet", now: Date = Date()) -> Event {
        let t = now.timeIntervalSince1970
        if inCall {
            if current == nil {
                var record = MeetingRecord(
                    id: Self.makeID(at: now), source: source, startedAt: t, endedAt: nil,
                    timeZone: TimeZone.current.identifier, title: nil, conferenceCode: nil,
                    participants: [], minutesState: "none", minutesError: nil)
                apply(meta, to: &record)
                if source == "meet" { record.lastHeartbeatAt = t }
                current = record
                lastSeen = t
                store.save(record)
                log("meeting started \(record.id)")
                return .started(record)
            }
            lastSeen = t
            guard var record = current else { return .none }
            let before = record
            apply(meta, to: &record)
            if record.source == "meet" { record.lastHeartbeatAt = t }
            current = record
            if record != before { store.save(record) }
            return .none
        }
        guard var record = current else { return .none }
        // A Meet call ends when its heartbeat has been silent for a while, so
        // the last heartbeat is the last sign of life. A meeting ended by hand
        // has no heartbeat: the click itself is that moment.
        let lastAlive = record.source == "manual" ? t : lastSeen
        record.endedAt = max(record.startedAt, lastAlive) + Self.tailSeconds
        current = nil
        lastSeen = 0
        store.save(record)
        log("meeting ended \(record.id) participants=\(record.participants.count)")
        return .ended(record)
    }

    private func apply(_ meta: MeetingHeartbeatMeta?, to record: inout MeetingRecord) {
        guard let meta else { return }
        if record.conferenceCode == nil { record.conferenceCode = meta.code }
        if record.title == nil {
            record.title = MeetingHeartbeatMeta.cleanTitle(meta.title, code: meta.code ?? record.conferenceCode)
        }
        for name in meta.roster where !record.participants.contains(name) {
            record.participants.append(name)
        }
    }

    /// `mtg-2026-09-21T10-31-02Z`, the same shape as a session id.
    static func makeID(at date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return "mtg-" + fmt.string(from: date)
    }
}

/// Where meeting records live: `ambient-context/meetings/<id>/meeting.json`.
struct MeetingStore {
    struct SpeakerCorrection: Codable {
        let capturedAt: Double
        let stream: String
        let text: String
        let name: String
    }
    let root: URL

    init(root: URL = AmbientStorage.ambientRoot.appendingPathComponent("meetings", isDirectory: true)) {
        self.root = root
    }

    func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func save(_ record: MeetingRecord) {
        let dir = directory(for: record.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
        } catch {
            // A meeting record is a convenience on top of the transcript, never
            // a precondition for capture: a failed write must not stop a call.
        }
    }

    func load(id: String) -> MeetingRecord? {
        let url = directory(for: id).appendingPathComponent("meeting.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeetingRecord.self, from: data)
    }

    /// A backfill revision is separate from the ambient session transcript.
    func saveBackfill(_ segments: [TranscriptSegment], for record: MeetingRecord) throws {
        let dir = directory(for: record.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let corrected = applySpeakerCorrections(segments, id: record.id)
        try JSONEncoder().encode(corrected).write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    func loadBackfill(id: String) -> [TranscriptSegment]? {
        let url = directory(for: id).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    func audioClip(id: String, segment: TranscriptSegment) -> (url: URL, offset: TimeInterval)? {
        guard let at = segment.capturedAt, let stream = segment.stream else { return nil }
        let directory = directory(for: id).appendingPathComponent("audio", isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let chunks = try? JSONDecoder().decode([MeetingAudioArchive.Chunk].self, from: data),
              let chunk = chunks.first(where: { $0.source == stream && $0.startedAt <= at && at < $0.endedAt }) else {
            return nil
        }
        let url = directory.appendingPathComponent(chunk.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, at - chunk.startedAt)
    }

    func labelSpeaker(id: String, segment: TranscriptSegment, name: String) throws {
        guard let at = segment.capturedAt, let stream = segment.stream,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var transcript = loadBackfill(id: id) else { return }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var corrections = speakerCorrections(id: id)
        corrections.removeAll { $0.stream == stream && abs($0.capturedAt - at) < 0.01 }
        corrections.append(SpeakerCorrection(capturedAt: at, stream: stream,
                                             text: segment.text, name: label))
        let dir = directory(for: id)
        try JSONEncoder().encode(corrections).write(
            to: dir.appendingPathComponent("speaker-corrections.json"), options: .atomic)
        transcript = applySpeakerCorrections(transcript, id: id)
        try JSONEncoder().encode(transcript).write(
            to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    private func speakerCorrections(id: String) -> [SpeakerCorrection] {
        let url = directory(for: id).appendingPathComponent("speaker-corrections.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SpeakerCorrection].self, from: data)) ?? []
    }

    private func applySpeakerCorrections(_ segments: [TranscriptSegment], id: String) -> [TranscriptSegment] {
        let corrections = speakerCorrections(id: id)
        return segments.map { segment in
            var changed = segment
            if let at = segment.capturedAt,
               let correction = corrections.filter({ $0.stream == segment.stream &&
                   $0.text == segment.text && abs($0.capturedAt - at) <= 1 }).min(by: {
                   abs($0.capturedAt - at) < abs($1.capturedAt - at)
               }) {
                changed.speakerName = correction.name
            }
            return changed
        }
    }

    /// The transcript and minutes remain; only pinned meeting audio expires.
    func pruneArchivedAudio(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        for record in all() {
            let audio = directory(for: record.id).appendingPathComponent("audio", isDirectory: true)
            let index = audio.appendingPathComponent("index.json")
            guard let pinnedAt = try? index.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  pinnedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: audio)
        }
    }

    /// Ends any meeting still marked open. Legacy records without a persisted
    /// heartbeat use their last write as the last sign of life.
    @discardableResult
    func closeOpenMeetings() -> [MeetingRecord] {
        var closed: [MeetingRecord] = []
        for var record in all() where record.isOpen {
            let file = directory(for: record.id).appendingPathComponent("meeting.json")
            let lastWrite = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
                .flatMap { $0 }?.timeIntervalSince1970
            record.endedAt = max(record.startedAt, record.lastHeartbeatAt ?? lastWrite ?? record.startedAt)
                + MeetingRecorder.tailSeconds
            save(record)
            closed.append(record)
        }
        return closed
    }

    /// Newest first.
    func all() -> [MeetingRecord] {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return dirs.filter { $0.hasPrefix("mtg-") }
            .compactMap { load(id: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}
