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

    /// Ends any meeting still marked open, using the record's own last write as
    /// the last sign of life. Returns what it closed.
    @discardableResult
    func closeOpenMeetings() -> [MeetingRecord] {
        var closed: [MeetingRecord] = []
        for var record in all() where record.isOpen {
            let file = directory(for: record.id).appendingPathComponent("meeting.json")
            let lastWrite = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
                .flatMap { $0 }?.timeIntervalSince1970
            record.endedAt = max(record.startedAt, lastWrite ?? record.startedAt) + MeetingRecorder.tailSeconds
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
