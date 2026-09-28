import Foundation
import CryptoKit

/// Calendar identity is independent of audio overlap. A candidate may suggest
/// audio for review, but that suggestion cannot attach an existing document.
enum MeetingWorkspace {
    static func associatedRecord(candidate: MeetingCandidate, records: [MeetingRecord]) -> MeetingRecord? {
        let active = records.filter { $0.mergedIntoMeetingID == nil }
        let explicit = active.filter {
            $0.materialCandidateID == candidate.id ||
            ($0.calendarEventID == candidate.calendarEventID && $0.calendarID == candidate.calendarID &&
             abs(($0.calendarEventStart ?? $0.startedAt) - candidate.start.timeIntervalSince1970) < 1)
        }
        if explicit.count == 1 { return explicit[0] }
        guard explicit.isEmpty, let code = candidate.conferenceCode, !code.isEmpty else { return nil }
        let matching = active.filter {
            $0.conferenceCode == code && $0.startedAt < candidate.end.timeIntervalSince1970 &&
            ($0.endedAt ?? $0.startedAt) > candidate.start.timeIntervalSince1970
        }
        return matching.count == 1 ? matching[0] : nil
    }

    static func record(candidate: MeetingCandidate, existing: MeetingRecord?) -> MeetingRecord {
        let hash = SHA256.hash(data: Data(candidate.id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        var record = existing ?? MeetingRecord(id: "mtg-calendar-" + hash, source: "calendar",
            startedAt: candidate.start.timeIntervalSince1970, endedAt: candidate.end.timeIntervalSince1970,
            timeZone: TimeZone.current.identifier, title: candidate.title,
            conferenceCode: candidate.conferenceCode, participants: [], minutesState: "none", minutesError: nil)
        record.calendarID = candidate.calendarID
        record.calendarEventID = candidate.calendarEventID
        record.calendarEventStart = candidate.start.timeIntervalSince1970
        record.calendarEventEnd = candidate.end.timeIntervalSince1970
        record.materialCandidateID = candidate.id
        return record
    }

    private static var cacheURL: URL {
        MeetingGoogleMaterials.defaultCacheDirectory().appendingPathComponent("calendar-candidates.json")
    }

    static func cachedCandidates() -> [MeetingCandidate] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? JSONDecoder().decode([MeetingCandidate].self, from: data)) ?? []
    }

    static func saveCandidates(_ candidates: [MeetingCandidate]) throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(candidates).write(to: cacheURL, options: .atomic)
    }
}
