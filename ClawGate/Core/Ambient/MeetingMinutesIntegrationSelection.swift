import Foundation

/// An explicit selection of immutable local source revisions, inside the
/// existing meeting store. This neither merges records nor publishes anything.
struct MeetingMinutesIntegrationSelection: Codable {
    struct Source: Codable {
        let record: MeetingRecord
        let authority: String
        let revision: String
        let bytes: Data

        func enqueue(in ledger: MeetingMinutesKnowledgeOutbox) throws {
            if authority == "accepted" {
                try ledger.enqueue(acceptedData: bytes, record: record, explicitlySelected: true)
            } else {
                try ledger.enqueue(exportedData: bytes, record: record)
            }
        }

        func snapshotData() throws -> Data {
            let snapshot = authority == "accepted"
                ? try MeetingMinutesKnowledgeSnapshot(acceptedData: bytes, record: record, explicitlySelected: true)
                : try MeetingMinutesKnowledgeSnapshot(exportedData: bytes, record: record)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(snapshot)
        }
    }
    enum Failure: Error, LocalizedError {
        case invalidSelection, unavailable, changed, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidSelection: return "統合する会議を確認できません"
            case .unavailable: return "選択した議事録を読み取れません。現在の議事録は保持しています"
            case .changed: return "保存した統合資料の版を確認できません。資料を選び直してください"
            case .tooLarge: return "統合資料が50MBを超えています。資料を分けてください"
            }
        }
    }
    static let fileName = "minutes-integration.json"
    private static let limit = 50 * 1024 * 1024
    let version: Int
    let targetMeetingID: String
    let sourceUUID: String
    let sources: [Source]

    static func select(targetID: String, otherIDs: [String], sourceUUID: String,
                       store: MeetingStore) throws {
        let ids = [targetID] + otherIDs.filter { $0 != targetID }
        guard UUID(uuidString: sourceUUID) != nil, Set(ids).count == ids.count,
              ids.allSatisfy(validID), let target = store.load(id: targetID),
              target.minutesState != "pending" else { throw Failure.invalidSelection }
        var values: [Source] = []
        var total = 0
        if !otherIDs.isEmpty {
            for id in ids {
                guard let record = store.load(id: id) else { throw Failure.unavailable }
                let directory = store.directory(for: id)
                let accepted = directory.appendingPathComponent("minutes-accepted.json")
                let authority = FileManager.default.fileExists(atPath: accepted.path) ? "accepted" : "legacy-export"
                let path = authority == "accepted" ? accepted : directory.appendingPathComponent("minutes.json")
                let data = try read(path)
                total += data.count
                guard total <= limit else { throw Failure.tooLarge }
                if authority == "accepted" { _ = try JSONDecoder().decode(MeetingAcceptedMinutes.self, from: data) }
                else { _ = try JSONDecoder().decode(MeetingMinutes.self, from: data) }
                values.append(Source(record: record, authority: authority,
                    revision: MeetingMinutesPublication.digest(data), bytes: data))
            }
        }
        let value = Self(version: 1, targetMeetingID: targetID, sourceUUID: sourceUUID, sources: values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= limit else { throw Failure.tooLarge }
        let url = store.directory(for: targetID).appendingPathComponent(fileName)
        _ = try AudioHubOutbox.persist(value, to: url, maxBytes: limit)
    }

    static func load(targetID: String, store: MeetingStore) throws -> Self? {
        guard validID(targetID) else { throw Failure.invalidSelection }
        let path = store.directory(for: targetID).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: read(path))
        guard value.version == 1, value.targetMeetingID == targetID,
              UUID(uuidString: value.sourceUUID) != nil,
              Set(value.sources.map { $0.record.id }).count == value.sources.count,
              value.sources.isEmpty || value.sources.contains(where: { $0.record.id == targetID }),
              value.sources.allSatisfy({ validID($0.record.id) &&
                  ["accepted", "legacy-export"].contains($0.authority) &&
                  MeetingMinutesPublication.digest($0.bytes) == $0.revision }) else { throw Failure.changed }
        return value.sources.isEmpty ? nil : value
    }

    func segments() throws -> [MeetingTranscriptSourceSegment] {
        try sources.flatMap { source in
            let locator = "clawgate:\(sourceUUID)/\(source.record.id)/\(source.authority)/\(source.revision)"
            let prefix = "integrated-" + MeetingMinutesPublication.digest(Data(locator.utf8)) + "-"
            var raw: [MeetingTranscriptSourceSegment] = []
            let minutes: MeetingMinutes
            if source.authority == "accepted" {
                let accepted = try JSONDecoder().decode(MeetingAcceptedMinutes.self, from: source.bytes)
                minutes = accepted.minutes
                raw = accepted.segments.map { segment in
                    MeetingTranscriptSourceSegment(id: prefix + segment.id, source: segment.source,
                        text: segment.text, speaker: segment.speakerName ?? segment.speaker,
                        capturedAt: segment.capturedAt, sourceURL: segment.sourceURL,
                        sourceLocator: locator + "#" + segment.id + " · " + (segment.sourceLocator ?? "original segment"),
                        startSeconds: segment.startSeconds, endSeconds: segment.endSeconds,
                        recallLineage: segment.recallLineage)
                }
            } else {
                minutes = try JSONDecoder().decode(MeetingMinutes.self, from: source.bytes)
            }
            let text = minutes.markdown(record: source.record,
                now: Date(timeIntervalSince1970: source.record.endedAt ?? source.record.startedAt))
            return raw + MeetingMinutesSecondaryEvidence.segments(text: text, id: prefix + "minutes",
                sourceURL: nil, locator: locator)
        }
    }

    private static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil
    }
    private static func read(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw Failure.unavailable }
        guard (info.fileSize ?? Int.max) <= limit else { throw Failure.tooLarge }
        return try Data(contentsOf: url)
    }
}
