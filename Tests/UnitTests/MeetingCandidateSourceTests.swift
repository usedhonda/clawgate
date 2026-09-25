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

    private func speech(_ text: String, at: Double) -> TranscriptSegment {
        var segment = TranscriptSegment(startSeconds: 0, endSeconds: 2, text: text)
        segment.capturedAt = at
        segment.stream = "mic"
        return segment
    }

    func testOverlappingCalendarEventsKeepAmbiguousRealConversationBoundsAndMeetRecord() {
        let named = try! JSONDecoder().decode(MeetingCandidateSource.Event.self, from: Data(
            #"{"id":"generic","summary":"Meeting","start":{"dateTime":"1970-01-01T00:10:00Z"},"end":{"dateTime":"1970-01-01T00:40:00Z"},"attendees":[{"displayName":"Example Speaker"}]}"#.utf8))
        let events = [named,
                      event(id: "weekly", start: "1970-01-01T00:10:00Z", end: "1970-01-01T00:40:00Z")]
        let audio = [MeetingAudioArchive.Chunk(id: "mic", source: "mic", startedAt: 590,
                                                endedAt: 1_550, fileName: "mic.m4a")]
        let record = MeetingRecord(id: "mtg-existing", source: "meet", startedAt: 602,
                                   endedAt: 1_480, timeZone: "UTC", title: nil,
                                   conferenceCode: nil, participants: [], minutesState: "failed", minutesError: nil)
        var namedSpeech = speech("よろしくお願いします", at: 610)
        namedSpeech.speakerName = "Example Speaker"
        let found = MeetingCandidateSource.makeCandidates(
            events: events, chunks: audio,
            rough: [namedSpeech, speech("議題を話します", at: 1_000),
                    speech("ありがとうございました", at: 1_390)],
            from: from, to: to, records: [record])
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.allSatisfy { $0.matchStatus == "ambiguous" && $0.matchedMeetingID == record.id })
        XCTAssertEqual(found.first?.proposedStart?.timeIntervalSince1970, 595)
        XCTAssertEqual(found.first?.proposedEnd?.timeIntervalSince1970, 1_480)
        XCTAssertTrue(found.first { $0.calendarEventID == "generic" }?.boundaryEvidence.contains("1 件一致") == true)
    }

    func testSplitMeetRecordsChooseLongReadyTargetAndReportShortInternalAudioGap() {
        let chunks = [
            MeetingAudioArchive.Chunk(id: "mic-before", source: "mic", startedAt: 600,
                                      endedAt: 1_680, fileName: "before.m4a"),
            MeetingAudioArchive.Chunk(id: "mic-after", source: "mic", startedAt: 1_920,
                                      endedAt: 4_200, fileName: "after.m4a"),
        ]
        let short = MeetingRecord(id: "mtg-short", source: "meet", startedAt: 600,
                                  endedAt: 660, timeZone: "UTC", title: nil,
                                  conferenceCode: nil, participants: [], minutesState: "none", minutesError: nil)
        let ready = MeetingRecord(id: "mtg-ready", source: "meet", startedAt: 1_980,
                                  endedAt: 4_170, timeZone: "UTC", title: nil,
                                  conferenceCode: nil, participants: [], minutesState: "ready", minutesError: nil)
        let proposal = MeetingBoundaryProposal.infer(eventStart: 600, eventEnd: 3_600,
            rough: [speech("まず共有します", at: 610), speech("次の内容です", at: 1_000),
                    speech("さらに共有します", at: 1_400), speech("続きを説明します", at: 1_670),
                    speech("引き続き共有します", at: 1_930), speech("論点を確認します", at: 2_350),
                    speech("次の議題です", at: 2_750), speech("意見をまとめます", at: 3_150),
                    speech("結論を確認します", at: 3_550), speech("まとめを確認します", at: 3_900),
                    speech("ありがとうございました", at: 4_120)],
            chunks: chunks, records: [short, ready])
        XCTAssertEqual(proposal.record?.id, ready.id)
        XCTAssertEqual(Set(proposal.matchingRecordIDs), Set([short.id, ready.id]))
        XCTAssertTrue(proposal.evidence.contains("録音に欠落あり"))
        XCTAssertTrue(proposal.ambiguous)
    }

    func testContinuousRecordingWithoutConversationDoesNotInventMeetingBounds() {
        let audio = [MeetingAudioArchive.Chunk(id: "mic", source: "mic", startedAt: 600,
                                                endedAt: 1_200, fileName: "mic.m4a")]
        let found = MeetingCandidateSource.makeCandidates(
            events: [event(id: "empty", start: "1970-01-01T00:10:00Z", end: "1970-01-01T00:20:00Z")],
            chunks: audio, rough: [speech("あ", at: 700)], from: from, to: to)
        XCTAssertEqual(found.first?.microphoneSeconds, 600)
        XCTAssertEqual(found.first?.matchStatus, "noConversation")
        XCTAssertNil(found.first?.proposedStart)
    }

    func testConversationCanStartBeforeAndEndAfterScheduledInterval() {
        let audio = [MeetingAudioArchive.Chunk(id: "mic", source: "mic", startedAt: 540,
                                                endedAt: 1_300, fileName: "mic.m4a")]
        let found = MeetingCandidateSource.makeCandidates(
            events: [event(id: "shifted", start: "1970-01-01T00:10:00Z", end: "1970-01-01T00:20:00Z")],
            chunks: audio,
            rough: [speech("それでは始めます", at: 580), speech("議題を続けます", at: 900),
                    speech("これで終わります", at: 1_230)],
            from: from, to: to)
        XCTAssertEqual(found.first?.matchStatus, "suggested")
        XCTAssertEqual(found.first?.proposedStart?.timeIntervalSince1970, 565)
        XCTAssertEqual(found.first?.proposedEnd?.timeIntervalSince1970, 1_260)
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

    func testCalendarCandidateWithoutMicIsVisibleButNotReady() {
        let chunks = [MeetingAudioArchive.Chunk(id: "system", source: "system", startedAt: 600,
                                                 endedAt: 900, fileName: "system.m4a")]
        let meeting = event(id: "meeting", start: "1970-01-01T00:10:00Z", end: "1970-01-01T00:15:00Z")
        let candidates = MeetingCandidateSource.makeCandidates(
            events: [meeting],
            chunks: chunks, rough: [], from: from, to: to)
        XCTAssertEqual(candidates.map(\.id), ["meeting"])
        XCTAssertEqual(candidates.first?.microphoneSeconds, 0)
        let withMic = MeetingCandidateSource.makeCandidates(
            events: [meeting],
            chunks: chunks + [MeetingAudioArchive.Chunk(id: "mic", source: "mic", startedAt: 600,
                                                         endedAt: 900, fileName: "mic.m4a")],
            rough: [], from: from, to: to)
        XCTAssertEqual(withMic.map(\.id), ["meeting"])
        XCTAssertEqual(withMic.first?.microphoneSeconds, 300)
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
