import Foundation

struct MeetingCandidate: Identifiable, Equatable {
    let id: String
    let calendarID: String?
    let calendarEventID: String
    let title: String
    let start: Date
    let end: Date
    let microphoneSeconds: Int
    let roughCharacters: Int
    let proposedStart: Date?
    let proposedEnd: Date?
    let boundaryEvidence: String
    /// suggested | ambiguous | noConversation
    let matchStatus: String
    let matchedMeetingID: String?
    let matchingMeetingIDs: [String]
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
        struct Attendee: Decodable { let displayName: String? }
        let id: String
        let iCalUID: String?
        let summary: String?
        let status: String?
        let eventType: String?
        let transparency: String?
        let start: Endpoint?
        let end: Endpoint?
        let hangoutLink: String?
        let attendees: [Attendee]?
        var calendarID: String? = nil
    }

    private static func endpointDate(_ endpoint: Event.Endpoint?) -> Date? {
        guard let dateTime = endpoint?.dateTime else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return parser.date(from: dateTime) ?? plain.date(from: dateTime)
    }

    static func candidates(now: Date = Date(),
                           archive: MeetingAudioArchive = MeetingAudioArchive()) throws -> [MeetingCandidate] {
        let from = now.addingTimeInterval(-MeetingAudioArchive.retentionSeconds)
        let events = try fetchEvents(from: from, to: now)
        let rough = AmbientStorage.segmentsInRange(start: from.timeIntervalSince1970,
                                                   end: now.timeIntervalSince1970)
        return makeCandidates(events: events, chunks: archive.allChunks(), rough: rough,
                              from: from, to: now, records: MeetingStore().all())
    }

    static func makeCandidates(events: [Event], chunks: [MeetingAudioArchive.Chunk],
                               rough: [TranscriptSegment], from: Date, to: Date,
                               records: [MeetingRecord] = []) -> [MeetingCandidate] {
        return events.compactMap { event -> MeetingCandidate? in
            guard event.status != "cancelled",
                  (event.eventType ?? "default") == "default",
                  event.transparency != "transparent",
                  let start = endpointDate(event.start),
                  let end = endpointDate(event.end),
                  start < end,
                  end > from,
                  start < to else { return nil }
            let first = start.timeIntervalSince1970
            let last = end.timeIntervalSince1970
            let intervals = chunks.filter { $0.source == "mic" && $0.startedAt < last && $0.endedAt > first }
                .map { (max(first, $0.startedAt), min(last, $0.endedAt)) }
                .sorted { $0.0 < $1.0 }
            var covered = 0.0
            var through = first
            for (begin, finish) in intervals {
                let newBegin = max(begin, through)
                if finish > newBegin { covered += finish - newBegin }
                through = max(through, finish)
            }
            let characters = rough.filter { ($0.capturedAt ?? -.infinity) >= first &&
                ($0.capturedAt ?? .infinity) < last }.reduce(0) { $0 + $1.text.count }
            let proposal = MeetingBoundaryProposal.infer(eventStart: first, eventEnd: last,
                rough: rough, chunks: chunks, records: records)
            let competing = events.contains { other in
                guard other.id != event.id || other.calendarID != event.calendarID,
                      let otherStart = endpointDate(other.start),
                      let otherEnd = endpointDate(other.end) else { return false }
                return otherStart < end && otherEnd > start &&
                    other.status != "cancelled" && (other.eventType ?? "default") == "default" &&
                    other.transparency != "transparent"
            }
            let exactCode = proposal.record?.conferenceCode.flatMap { code in
                event.hangoutLink?.contains(code)
            } ?? false
            let status = proposal.start == nil ? "noConversation" :
                ((proposal.ambiguous || (competing && !exactCode)) ? "ambiguous" : "suggested")
            let observedNames = Set(rough.compactMap { segment -> String? in
                guard let at = segment.capturedAt, let begin = proposal.start, let finish = proposal.end,
                      at >= begin, at <= finish, let name = segment.speakerName else { return nil }
                return name.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
            })
            let invitedNames = Set((event.attendees ?? []).compactMap { attendee -> String? in
                attendee.displayName?.replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "　", with: "")
            })
            let nameMatches = observedNames.intersection(invitedNames).count
            let evidence = proposal.evidence + (nameMatches > 0 ? "・招待者名と話者名 \(nameMatches) 件一致" : "")
            let candidateID = event.calendarID.map { $0 + ":" + event.id + ":" + String(Int(first)) } ?? event.id
            return MeetingCandidate(id: candidateID, calendarID: event.calendarID,
                                    calendarEventID: event.id,
                                    title: event.summary ?? "予定",
                                    start: start, end: end,
                                    microphoneSeconds: Int(covered), roughCharacters: characters,
                                    proposedStart: proposal.start.map(Date.init(timeIntervalSince1970:)),
                                    proposedEnd: proposal.end.map(Date.init(timeIntervalSince1970:)),
                                    boundaryEvidence: evidence, matchStatus: status,
                                    matchedMeetingID: proposal.record?.id,
                                    matchingMeetingIDs: proposal.matchingRecordIDs)
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
                    for var event in found {
                        let key = (event.iCalUID ?? event.id) + "\u{0}" + (event.start?.dateTime ?? "") + "\u{0}" + (event.end?.dateTime ?? "")
                        event.calendarID = calendar.id
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
