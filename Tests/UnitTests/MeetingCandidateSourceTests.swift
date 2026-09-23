import XCTest
@testable import ClawGate

final class MeetingCandidateSourceTests: XCTestCase {
    private let from = Date(timeIntervalSince1970: 0)
    private let to = Date(timeIntervalSince1970: 3600)

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
