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
        enum CalendarReason { case service, unauthenticated }
        case clientUnavailable
        case calendarUnavailable(CalendarReason = .service)
        case incompleteCalendarResult
    }

    private struct Accounts: Decodable {
        struct Account: Decodable { let email: String }
        let accounts: [Account]
    }
    private struct AuthStatus: Decodable {
        struct Account: Decodable { let email: String? }
        let account: Account
    }

    static func calendarAuthorizationArguments(status: Data) throws -> [String] {
        let email = try JSONDecoder().decode(AuthStatus.self, from: status).account.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email, !email.isEmpty else { throw Failure.calendarUnavailable(.unauthenticated) }
        return ["auth", "add", email, "--services=calendar", "--readonly"]
    }
    private struct Calendars: Decodable {
        struct Calendar: Decodable { let id: String }
        let calendars: [Calendar]
        let nextPageToken: String?
    }
    private struct Response: Decodable {
        let events: [Event]
        let nextPageToken: String?
    }
    struct Event: Decodable {
        struct Endpoint: Decodable { let dateTime: String? }
        let id: String
        let iCalUID: String?
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

    typealias Runner = ([String]) throws -> Data

    private static func fetchEvents(from: Date, to: Date) throws -> [Event] {
        let locations = ["/opt/homebrew/bin/gog", "/usr/local/bin/gog"]
        guard let binary = locations.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw Failure.clientUnavailable
        }
        return try fetchEvents(from: from, to: to) { arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments + ["--json", "--no-input"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw Failure.clientUnavailable }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.calendarUnavailable() }
            return data
        }
    }

    static func fetchEvents(from: Date, to: Date, run: Runner) throws -> [Event] {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        let accounts: Accounts
        do { accounts = try JSONDecoder().decode(Accounts.self, from: run(["auth", "list"])) }
        catch { throw Failure.clientUnavailable }
        guard !accounts.accounts.isEmpty else { throw Failure.calendarUnavailable(.unauthenticated) }
        var events: [Event] = []
        var seen = Set<String>()
        var failed = false
        var readAnyPage = false
        for account in accounts.accounts {
            guard !account.email.isEmpty else { failed = true; continue }
            let accountArg = "--account=" + account.email
            let calendars: [Calendars.Calendar]
            do {
                calendars = try pages { page in
                    let data = try run(["calendar", "calendars", accountArg, "--max=100"] + (page.map { ["--page=" + $0] } ?? []))
                    let response = try JSONDecoder().decode(Calendars.self, from: data)
                    readAnyPage = true
                    return (response.calendars, response.nextPageToken)
                }
            } catch { failed = true; continue }
            for calendar in calendars where !calendar.id.isEmpty {
                do {
                    let found: [Event] = try pages { page in
                        let args = ["calendar", "events", calendar.id, accountArg,
                                    "--from=" + format.string(from: from), "--to=" + format.string(from: to),
                                    "--max=500"] + (page.map { ["--page=" + $0] } ?? [])
                        let response = try JSONDecoder().decode(Response.self, from: run(args))
                        readAnyPage = true
                        return (response.events, response.nextPageToken)
                    }
                    for event in found {
                        let key = (event.iCalUID ?? event.id) + "\u{0}" + (event.start?.dateTime ?? "") + "\u{0}" + (event.end?.dateTime ?? "")
                        if seen.insert(key).inserted { events.append(event) }
                    }
                } catch { failed = true }
            }
        }
        if failed {
            throw readAnyPage ? Failure.incompleteCalendarResult : Failure.calendarUnavailable()
        }
        return events
    }

    private static func pages<T>(_ load: (String?) throws -> ([T], String?)) throws -> [T] {
        var items: [T] = []
        var page: String?
        var tokens = Set<String>()
        repeat {
            let (batch, next) = try load(page)
            items += batch
            guard let next, !next.isEmpty else { return items }
            guard tokens.insert(next).inserted else { throw Failure.incompleteCalendarResult }
            page = next
        } while true
    }
}
