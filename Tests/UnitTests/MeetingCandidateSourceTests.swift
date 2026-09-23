import XCTest
@testable import ClawGate

final class MeetingCandidateSourceTests: XCTestCase {
    private let from = Date(timeIntervalSince1970: 0)
    private let to = Date(timeIntervalSince1970: 3600)

    private func event(id: String, start: String, end: String, dateOnly: Bool = false) -> MeetingCandidateSource.Event {
        let endpointKey = dateOnly ? "date" : "dateTime"
        let object: [String: Any] = [
            "id": id, "summary": "Meeting",
            "start": [endpointKey: start], "end": [endpointKey: end]
        ]
        return try! JSONDecoder().decode(MeetingCandidateSource.Event.self,
            from: try! JSONSerialization.data(withJSONObject: object))
    }

    func testAllDayEventsAreNotMistakenForMeetingsWhenMicAudioOverlaps() {
        let chunks = [MeetingAudioArchive.Chunk(id: "mic", source: "mic", startedAt: 86_410,
                                                 endedAt: 86_420, fileName: "mic.m4a")]
        let candidates = MeetingCandidateSource.makeCandidates(
            events: [event(id: "all-day", start: "1970-01-02", end: "1970-01-03", dateOnly: true)],
            chunks: chunks, rough: [], from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 172_800))
        XCTAssertTrue(candidates.isEmpty)
    }

    func testSystemAudioAloneDoesNotCreateCalendarCandidate() {
        let chunks = [MeetingAudioArchive.Chunk(id: "system", source: "system", startedAt: 600,
                                                 endedAt: 900, fileName: "system.m4a")]
        let meeting = event(id: "meeting", start: "1970-01-01T00:10:00Z", end: "1970-01-01T00:15:00Z")
        let candidates = MeetingCandidateSource.makeCandidates(
            events: [meeting],
            chunks: chunks, rough: [], from: from, to: to)
        XCTAssertTrue(candidates.isEmpty)
        let withMic = MeetingCandidateSource.makeCandidates(
            events: [meeting],
            chunks: chunks + [MeetingAudioArchive.Chunk(id: "mic", source: "mic", startedAt: 600,
                                                         endedAt: 900, fileName: "mic.m4a")],
            rough: [], from: from, to: to)
        XCTAssertEqual(withMic.map(\.id), ["meeting"])
    }

    func testOutOfOfficeAndTransparentEventsDoNotBecomeMeetingCandidates() {
        let audio = [MeetingAudioArchive.Chunk(id: "mic", source: "mic", startedAt: 600,
                                               endedAt: 900, fileName: "mic.m4a")]
        let outOfOffice = Data(#"{"id":"ooo","eventType":"outOfOffice","start":{"dateTime":"1970-01-01T00:00:00Z"},"end":{"dateTime":"1970-01-01T01:00:00Z"}}"#.utf8)
        let transparent = Data(#"{"id":"transparent","transparency":"transparent","start":{"dateTime":"1970-01-01T00:00:00Z"},"end":{"dateTime":"1970-01-01T01:00:00Z"}}"#.utf8)
        let events = [outOfOffice, transparent].map { try! JSONDecoder().decode(MeetingCandidateSource.Event.self, from: $0) }
        XCTAssertTrue(MeetingCandidateSource.makeCandidates(events: events, chunks: audio,
                        rough: [], from: from, to: to).isEmpty)
    }

    func testEnumeratesAccountsCalendarsAndEventPagesWithoutAll() throws {
        var calls: [[String]] = []
        let events = try MeetingCandidateSource.fetchEvents(from: from, to: to) { args in
            calls.append(args)
            if args == ["auth", "list"] {
                return Data(#"{"accounts":[{"email":"a@example.test"},{"email":"b@example.test"}]}"#.utf8)
            }
            if args.contains("--account=a@example.test"), args.contains("calendars") {
                return Data((args.contains("--page=next-cal")
                    ? #"{"calendars":[{"id":"second"}],"nextPageToken":""}"#
                    : #"{"calendars":[{"id":"first"}],"nextPageToken":"next-cal"}"#).utf8)
            }
            if args.contains("--account=b@example.test"), args.contains("calendars") {
                return Data(#"{"calendars":[{"id":"third"}],"nextPageToken":""}"#.utf8)
            }
            if args.contains("--page=next-event") {
                return Data(#"{"events":[{"id":"two","iCalUID":"shared","start":{"dateTime":"2026-01-01T10:00:00Z"}}],"nextPageToken":""}"#.utf8)
            }
            if args.contains("first") {
                return Data(#"{"events":[{"id":"one"}],"nextPageToken":"next-event"}"#.utf8)
            }
            return Data(#"{"events":[{"id":"two","iCalUID":"shared","start":{"dateTime":"2026-01-01T10:00:00Z"}}],"nextPageToken":""}"#.utf8)
        }
        XCTAssertEqual(events.map(\.id), ["one", "two"])
        XCTAssertEqual(calls.count, 8)
        XCTAssertFalse(calls.flatMap { $0 }.contains("--all"))
        XCTAssertTrue(calls.filter { $0.contains("events") }.allSatisfy { $0.contains(where: { $0.hasPrefix("--account=") }) })
    }

    func testNoAccountsIsUnauthenticated() {
        XCTAssertThrowsError(try MeetingCandidateSource.fetchEvents(from: from, to: to) { _ in
            Data(#"{"accounts":[]}"#.utf8)
        }) { error in
            guard case MeetingCandidateSource.Failure.calendarUnavailable(.unauthenticated) = error else {
                return XCTFail("Expected unauthenticated")
            }
        }
    }

    func testCalendarConnectionUsesConfiguredGOGAccountWithReadOnlyScope() throws {
        let status = Data(#"{"account":{"email":"user@example.test"}}"#.utf8)
        XCTAssertEqual(try MeetingCandidateSource.calendarAuthorizationArguments(status: status),
                       ["auth", "add", "user@example.test", "--services=calendar", "--readonly"])
        XCTAssertThrowsError(try MeetingCandidateSource.calendarAuthorizationArguments(
            status: Data(#"{"account":{"email":""}}"#.utf8)))
    }

    func testPartialPageFailureIsNotSilentlyAccepted() {
        XCTAssertThrowsError(try MeetingCandidateSource.fetchEvents(from: from, to: to) { args in
            if args == ["auth", "list"] { return Data(#"{"accounts":[{"email":"a@example.test"}]}"#.utf8) }
            if args.contains("calendars") { return Data(#"{"calendars":[{"id":"first"}],"nextPageToken":""}"#.utf8) }
            if args.contains("--page=again") { throw MeetingCandidateSource.Failure.calendarUnavailable() }
            return Data(#"{"events":[{"id":"one"}],"nextPageToken":"again"}"#.utf8)
        }) { error in
            guard case MeetingCandidateSource.Failure.incompleteCalendarResult = error else {
                return XCTFail("Expected incomplete result")
            }
        }
    }
}
