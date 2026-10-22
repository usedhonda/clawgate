import Foundation

enum MeetingMinutesSourceRevision {
    static func ambientRevision(record: MeetingRecord, files: [String: String], end: Double, sessionsRoot: URL) throws -> String {
        guard files["transcript.json"] == nil, record.source != "calendar" else { return "backfill" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: record.timeZone) ?? .current
        var day = calendar.startOfDay(for: Date(timeIntervalSince1970: record.startedAt))
        var revisions = [String(end)]
        while day.timeIntervalSince1970 <= end {
            try Task.checkCancellation()
            revisions.append(AmbientStorage.dayFingerprint(forDay: day, timeZone: calendar.timeZone, sessionsRoot: sessionsRoot))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return revisions.joined(separator: "|")
    }

    static func files(in directory: URL) throws -> [String: String] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
        } catch CocoaError.fileReadNoSuchFile { return [:] }
        return try Dictionary(uniqueKeysWithValues: urls.filter { $0.pathExtension == "json" }.map { url in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
            return (url.lastPathComponent, "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0):\(String(describing: values.fileResourceIdentifier))")
        })
    }
}
