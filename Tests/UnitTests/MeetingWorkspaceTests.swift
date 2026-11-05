import XCTest
@testable import ClawGate

final class MeetingWorkspaceTests: XCTestCase {
    private func candidate(id: String = "c", start: Double = 600, code: String? = nil) -> MeetingCandidate {
        MeetingCandidate(id: id, calendarID: "cal", calendarEventID: "event", title: "Review",
                         start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start + 1800),
                         microphoneSeconds: 20, roughCharacters: 0, proposedStart: nil, proposedEnd: nil,
                         boundaryEvidence: "", matchStatus: "suggested", matchedMeetingID: nil,
                         matchingMeetingIDs: [], conferenceCode: code, calendarURL: nil)
    }

    func testAssociatedRecordRequiresCalendarInstanceOrUniqueConferenceOverlap() {
        let c = candidate()
        let exact = MeetingRecord(id: "exact", source: "meet", startedAt: 600, endedAt: 1_000,
                                  timeZone: "UTC", title: nil, conferenceCode: nil, participants: [],
                                  minutesState: "none", minutesError: nil,
                                  calendarEventID: "event", calendarID: "cal", calendarEventStart: 600)
        XCTAssertEqual(MeetingWorkspace.associatedRecord(candidate: c, records: [exact])?.id, "exact")

        let wrongInstance = MeetingRecord(id: "wrong", source: "meet", startedAt: 600, endedAt: 1_000,
                                          timeZone: "UTC", title: nil, conferenceCode: nil, participants: [],
                                          minutesState: "none", minutesError: nil,
                                          calendarEventID: "event", calendarID: "cal", calendarEventStart: 900)
        XCTAssertNil(MeetingWorkspace.associatedRecord(candidate: c, records: [wrongInstance]))

        let byCode = candidate(id: "code", code: "abc")
        let coded = MeetingRecord(id: "coded", source: "meet", startedAt: 700, endedAt: 800,
                                  timeZone: "UTC", title: nil, conferenceCode: "abc", participants: [],
                                  minutesState: "none", minutesError: nil)
        XCTAssertEqual(MeetingWorkspace.associatedRecord(candidate: byCode, records: [coded])?.id, "coded")
    }

    func testCodelessMeetRecordChosenBySpeechIsReusedOnlyWhenItFitsTheEvent() {
        func suggested(_ id: String) -> MeetingCandidate {
            MeetingCandidate(id: "c", calendarID: "cal", calendarEventID: "event", title: "Review",
                             start: Date(timeIntervalSince1970: 600), end: Date(timeIntervalSince1970: 2_400),
                             microphoneSeconds: 20, roughCharacters: 0, proposedStart: nil, proposedEnd: nil,
                             boundaryEvidence: "", matchStatus: "suggested", matchedMeetingID: id,
                             matchingMeetingIDs: [id])
        }
        func meet(_ id: String, _ start: Double, _ end: Double, event: String? = nil) -> MeetingRecord {
            MeetingRecord(id: id, source: "meet", startedAt: start, endedAt: end, timeZone: "UTC", title: nil,
                          conferenceCode: nil, participants: [], minutesState: "ready", minutesError: nil,
                          calendarEventID: event)
        }
        XCTAssertEqual(MeetingWorkspace.associatedRecord(candidate: suggested("m"), records: [meet("m", 650, 2_300)])?.id, "m")
        // An earlier call that only touches the event's first minutes stays separate.
        XCTAssertNil(MeetingWorkspace.associatedRecord(candidate: suggested("m"), records: [meet("m", -3_000, 900)]))
        // A record already attached to another event is not taken.
        XCTAssertNil(MeetingWorkspace.associatedRecord(candidate: suggested("m"), records: [meet("m", 650, 2_300, event: "other")]))
    }
}
