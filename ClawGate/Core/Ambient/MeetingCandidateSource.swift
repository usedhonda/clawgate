import Foundation

struct MeetingCandidate: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let microphoneSeconds: Int
    let roughCharacters: Int
}

/// Read-only Google Calendar adapter. Calendar content stays on this Mac and
/// is used only to suggest an audio interval, never as evidence of attendance.
struct MeetingCandidateSource {
    enum Failure: Error {
        case clientUnavailable
        case calendarUnavailable
        case incompleteCalendarResult
    }

    private struct Response: Decodable {
        let events: [Event]
        let nextPageToken: String?
    }
    private struct Event: Decodable {
        struct Endpoint: Decodable { let dateTime: String? }
        let id: String
        let summary: String?
        let status: String?
        let start: Endpoint?
        let end: Endpoint?
    }

    static func candidates(now: Date = Date(),
                           archive: MeetingAudioArchive = MeetingAudioArchive()) throws -> [MeetingCandidate] {
        let from = now.addingTimeInterval(-MeetingAudioArchive.retentionSeconds)
        let events = try fetchEvents(from: from, to: now)
        let chunks = archive.allChunks().filter { $0.source == "mic" }
        let rough = AmbientStorage.segmentsInRange(start: from.timeIntervalSince1970,
                                                   end: now.timeIntervalSince1970)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return events.compactMap { event -> MeetingCandidate? in
            guard event.status != "cancelled",
                  let startText = event.start?.dateTime,
                  let endText = event.end?.dateTime,
                  let start = parser.date(from: startText) ?? plain.date(from: startText),
                  let end = parser.date(from: endText) ?? plain.date(from: endText),
                  start < end else { return nil }
            let first = start.timeIntervalSince1970
            let last = end.timeIntervalSince1970
            let intervals = chunks.filter { $0.startedAt < last && $0.endedAt > first }
                .map { (max(first, $0.startedAt), min(last, $0.endedAt)) }
                .sorted { $0.0 < $1.0 }
            var covered = 0.0
            var through = first
            for (begin, finish) in intervals {
                let newBegin = max(begin, through)
                if finish > newBegin { covered += finish - newBegin }
                through = max(through, finish)
            }
            guard covered > 0 else { return nil }
            let characters = rough.filter { ($0.capturedAt ?? -.infinity) >= first &&
                ($0.capturedAt ?? .infinity) < last }.reduce(0) { $0 + $1.text.count }
            return MeetingCandidate(id: event.id, title: event.summary ?? "予定",
                                    start: start, end: end,
                                    microphoneSeconds: Int(covered), roughCharacters: characters)
        }.sorted { $0.start > $1.start }
    }

    private static func fetchEvents(from: Date, to: Date) throws -> [Event] {
        let locations = ["/opt/homebrew/bin/gog", "/usr/local/bin/gog"]
        guard let binary = locations.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw Failure.clientUnavailable
        }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["calendar", "events", "--all", "--from=" + format.string(from: from),
                             "--to=" + format.string(from: to), "--max=500", "--json", "--no-input"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.clientUnavailable }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw Failure.calendarUnavailable
        }
        guard response.nextPageToken == nil || response.nextPageToken == "" else {
            throw Failure.incompleteCalendarResult
        }
        return response.events
    }
}
