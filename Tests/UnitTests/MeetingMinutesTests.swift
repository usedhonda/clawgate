import XCTest
@testable import ClawGate

/// The minutes envelope, the strict reply parser and the rendered Markdown.
/// Pure functions only — nothing here writes to the ambient store.
final class MeetingMinutesTests: XCTestCase {
    private func record(title: String? = "Weekly sync", zone: String = "Asia/Kolkata") -> MeetingRecord {
        MeetingRecord(id: "mtg-test", source: "meet",
                      startedAt: 1_790_000_000, endedAt: 1_790_003_600,
                      timeZone: zone, title: title, conferenceCode: "abc-defg-hij",
                      participants: ["田中", "佐藤"], minutesState: "none", minutesError: nil)
    }

    private func segment(_ text: String, at: Double, speaker: String? = nil,
                         stream: String? = "mic", name: String? = nil) -> TranscriptSegment {
        var s = TranscriptSegment(startSeconds: 0, endSeconds: 2, text: text)
        s.capturedAt = at
        s.speaker = speaker
        s.stream = stream
        s.speakerName = name
        return s
    }

    // MARK: - Request

    func testPendingMinutesAreOrderedByEndTimeAndIgnoreCompletedRecords() {
        func pending(_ id: String, _ startedAt: Double, _ endedAt: Double) -> MeetingRecord {
            MeetingRecord(id: id, source: "meet", startedAt: startedAt, endedAt: endedAt,
                          timeZone: "UTC", title: nil, conferenceCode: nil, participants: [],
                          minutesState: "pending", minutesError: nil)
        }
        let ready = MeetingRecord(id: "ready", source: "meet", startedAt: 1,
                                  endedAt: 2, timeZone: "UTC", title: nil,
                                  conferenceCode: nil, participants: [], minutesState: "ready", minutesError: nil)
        let ordered = PetModel.pendingMinutesOrder([
            pending("later", 30, 40), ready, pending("same-b", 10, 20), pending("same-a", 10, 20), pending("earlier", 5, 15)
        ])
        XCTAssertEqual(ordered.map(\.id), ["earlier", "same-a", "same-b", "later"])
    }

    func testBusyWaitsDoNotConsumeAttemptsAndDrainInOrderAfterCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-queue-\(UUID().uuidString)")
        let store = MeetingStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        func meeting(_ id: String, _ start: Double, _ end: Double) -> MeetingRecord {
            MeetingRecord(id: id, source: "meet", startedAt: start, endedAt: end,
                          timeZone: "UTC", title: id, conferenceCode: nil, participants: [],
                          minutesState: "none", minutesError: nil)
        }
        let first = meeting("mtg-first", 10, 40)
        let second = meeting("mtg-second", 20, 30) // overlapping, but ready earlier
        store.save(first)
        store.save(second)

        let model = PetModel()
        model.setMeetingStoreForTesting(store)
        model.setSessionKeyForTesting("test-session")
        model.setConnectionStateForTesting(.connected)
        model.meetingTranscriptProvider = { _ in [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "議題")] }
        model.suppressLogSendForTesting = true
        let busyToken = try XCTUnwrap(model.startSharedSummonForTesting(source: "log"))

        // Four queue pokes model the old retry intervals while the shared slot
        // remains busy. None may count as a generation attempt.
        for _ in 0..<4 {
            model.requestMinutes(for: first)
            model.requestMinutes(for: second)
        }
        XCTAssertEqual(model.minutesAttemptsForTesting["mtg-first", default: 0], 0)
        XCTAssertEqual(model.minutesAttemptsForTesting["mtg-second", default: 0], 0)

        model.releaseSharedSummonForTesting(token: busyToken)
        XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, "mtg-second")
        XCTAssertEqual(model.minutesAttemptsForTesting["mtg-second"], 1)

        // A terminal failure is still a real completion; the queue must then
        // advance to the remaining meeting rather than stall or duplicate.
        model.releaseCurrentSharedSummonForTesting()
        model.completeMinutesReplyForTesting("not JSON")
        XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, "mtg-first")
        XCTAssertEqual(model.minutesAttemptsForTesting["mtg-first"], 1)
    }

    func testEnvelopeNumbersSegmentsAndKeepsTheirStreamAndName() {
        let env = MeetingMinutesEnvelope.build(
            record: record(),
            segments: [segment("始めましょう", at: 1_790_000_010, speaker: "self"),
                       segment("よろしく", at: 1_790_000_020, speaker: "other", stream: "system", name: "田中")])
        XCTAssertEqual(env.segments.map(\.id), ["seg-1", "seg-2"])
        XCTAssertEqual(env.segments[1].stream, "system")
        XCTAssertEqual(env.segments[1].speakerName, "田中")
        XCTAssertEqual(env.participantsSeen, ["田中", "佐藤"])
        XCTAssertEqual(env.conferenceCode, "abc-defg-hij")
        XCTAssertEqual(env.policyVersion, MeetingMinutesPrompt.policyVersion)
    }

    func testSelectedCalendarAssociationIsPassedWithoutAskingModelToFindAnotherEvent() throws {
        var selected = record()
        selected.calendarEventID = "event-1"
        selected.calendarEventStart = selected.startedAt - 120
        selected.calendarEventEnd = selected.startedAt + 1800
        let env = MeetingMinutesEnvelope.build(record: selected, segments: [])
        XCTAssertEqual(env.calendarEventID, "event-1")
        XCTAssertNotNil(env.scheduledStartAt)
        XCTAssertNotNil(env.scheduledEndAt)
        let prompt = try MeetingMinutesPrompt.buildMessage(envelope: env)
        XCTAssertTrue(prompt.contains("外部の予定を検索・推測して結び付けない"))
    }

    func testTimesAreWrittenInTheZoneTheMeetingHappenedIn() {
        let env = MeetingMinutesEnvelope.build(record: record(zone: "Asia/Kolkata"), segments: [])
        XCTAssertTrue(env.startedAt.hasSuffix("+05:30"), env.startedAt)
        XCTAssertEqual(env.timeZone, "Asia/Kolkata")
    }

    func testTheMessageIsThePolicyPrefixFollowedByJSON() throws {
        let env = MeetingMinutesEnvelope.build(record: record(), segments: [segment("こんにちは", at: 1_790_000_010)])
        let message = try MeetingMinutesPrompt.buildMessage(envelope: env)
        XCTAssertTrue(message.hasPrefix("[\(MeetingMinutesPrompt.policyVersion)]"))
        let json = message.components(separatedBy: "\n\n").last ?? ""
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    func testPromptKeepsShortOverviewSeparateFromDetailedDiscussion() {
        let prompt = MeetingMinutesPrompt.universalPrefix()
        XCTAssertTrue(prompt.contains("`summary` は短い概要"))
        XCTAssertTrue(prompt.contains("`topics` は概要の言い換えではなく"))
        XCTAssertTrue(prompt.contains("終盤までの主要な論点"))
        XCTAssertTrue(prompt.contains("聞き取れない数字や食い違う表現"))
    }

    func testRenderedMinutesDiscloseKnownRecordingGap() throws {
        var interrupted = record()
        interrupted.boundaryEvidence = "録音に欠落あり"
        let minutes = try XCTUnwrap(MeetingMinutesParser.parse(
            reply(outcome: "answer", minutes: Self.sampleMinutes)))
        XCTAssertTrue(minutes.markdown(record: interrupted).contains("欠落区間の発言を網羅していません"))
    }

    // MARK: - Response

    private func reply(outcome: String, minutes: String, policy: String = MeetingMinutesPrompt.policyVersion) -> String {
        """
        {"outcome": "\(outcome)", "minutes": \(minutes),
         "contextDecision": {"policyVersion": "\(policy)"}}
        """
    }

    private static let sampleMinutes = """
    {"title": "Weekly sync", "summary": "来週の段取りを決めた。",
     "topics": [{"heading": "移行", "points": ["来週から始める"]}],
     "decisions": ["火曜に開始する"],
     "actionItems": [{"what": "資料を送る", "owner": "田中", "due": null, "mine": false},
                     {"what": "日程を確定する", "owner": null, "due": "金曜", "mine": true}],
     "openQuestions": ["二週目の担当"],
     "evidence": [
       {"claim":"来週の段取りを決めた。","segmentIds":["seg-1"]},
       {"claim":"来週から始める","segmentIds":["seg-1"]},
       {"claim":"火曜に開始する","segmentIds":["seg-1"]},
       {"claim":"資料を送る","segmentIds":["seg-1"]},
       {"claim":"日程を確定する","segmentIds":["seg-1"]},
       {"claim":"二週目の担当","segmentIds":["seg-1"]}],
     "attendance": {"present": ["田中"], "absent": ["佐藤"], "calendarEventId": null},
     "language": "ja"}
    """

    func testAValidAnswerParses() throws {
        let minutes = try MeetingMinutesParser.parse(reply(outcome: "answer", minutes: Self.sampleMinutes))
        XCTAssertEqual(minutes?.decisions, ["火曜に開始する"])
        XCTAssertEqual(minutes?.actionItems.count, 2)
        XCTAssertEqual(minutes?.attendance?.absent, ["佐藤"])
    }

    func testAttendanceCannotInventAbsenceOrChangeSelectedCalendarEvent() throws {
        let parsed = try XCTUnwrap(MeetingMinutesParser.parse(
            reply(outcome: "answer", minutes: Self.sampleMinutes)))
        let bound = parsed.boundToCalendarEvent("selected-event")
        XCTAssertEqual(bound.attendance?.present, ["田中"])
        XCTAssertEqual(bound.attendance?.absent, [])
        XCTAssertEqual(bound.attendance?.calendarEventId, "selected-event")
    }

    func testEvidenceMustResolveToInputSegment() {
        XCTAssertThrowsError(try MeetingMinutesParser.parse(
            reply(outcome: "answer", minutes: Self.sampleMinutes),
            validSegmentIds: ["seg-2"])) { error in
            // The failure has to name the claim and the rule, not just say
            // "invalid": the stored excerpt never contains the rejected claim.
            guard case .invalidEvidence(let claim, let reason)? = error as? MeetingMinutesError else {
                return XCTFail("expected invalidEvidence, got \(error)")
            }
            XCTAssertNotNil(claim, "the rejected claim must be named")
            XCTAssertTrue(reason.contains("segmentIds"), "reason names the rule: \(reason)")
        }
    }

    /// A multi-sentence summary may be cited sentence by sentence. 2026-09-24:
    /// a complete, correct set of minutes was refused on this one rule while
    /// every other claim (10 topic points, 5 decisions, 8 action items, 4 open
    /// questions) was cited — the model had grounded each sentence of the
    /// summary separately, which is stricter than one citation for the whole.
    func testAMultiSentenceSummaryMayBeCitedSentenceBySentence() throws {
        let body = """
        {"outcome":"answer","contextDecision":{"policyVersion":"\(MeetingMinutesPrompt.policyVersion)"},
         "minutes":{"title":"t","summary":"一文目です。\\n二文目です。","topics":[],"decisions":[],
         "actionItems":[],"openQuestions":[],
         "evidence":[{"claim":"一文目です。","segmentIds":["seg-1"]},
                     {"claim":"二文目です。","segmentIds":["seg-2"]}]}}
        """
        let minutes = try MeetingMinutesParser.parse(body, validSegmentIds: ["seg-1", "seg-2"])
        XCTAssertEqual(minutes?.title, "t")
    }

    /// The relaxation is about granularity, not grounding: a sentence nobody
    /// cited still fails, and the failure names it.
    func testAnUncitedSummarySentenceStillFails() {
        let body = """
        {"outcome":"answer","contextDecision":{"policyVersion":"\(MeetingMinutesPrompt.policyVersion)"},
         "minutes":{"title":"t","summary":"引用ありの文です。\\n引用なしの文です。","topics":[],
         "decisions":[],"actionItems":[],"openQuestions":[],
         "evidence":[{"claim":"引用ありの文です。","segmentIds":["seg-1"]}]}}
        """
        XCTAssertThrowsError(try MeetingMinutesParser.parse(body, validSegmentIds: ["seg-1"])) { error in
            guard case .invalidEvidence(let claim, _)? = error as? MeetingMinutesError else {
                return XCTFail("expected invalidEvidence, got \(error)")
            }
            XCTAssertEqual(claim, "引用なしの文です。")
        }
    }

    /// A one-sentence summary is unchanged by the split, so the single citation
    /// the prompt asks for keeps working.
    func testASingleSentenceSummaryIsStillOneClaim() throws {
        XCTAssertEqual(MeetingMinutesParser.summarySentences("ひとつの文です。"), ["ひとつの文です。"])
        XCTAssertEqual(MeetingMinutesParser.summarySentences("句点なしの要約"), ["句点なしの要約"])
    }

    func testInsufficientEvidenceParsesAsNoMinutes() throws {
        XCTAssertNil(try MeetingMinutesParser.parse(reply(outcome: "insufficientEvidence", minutes: "null")))
    }

    func testAnAnswerWithoutMinutesIsRejected() {
        XCTAssertThrowsError(try MeetingMinutesParser.parse(reply(outcome: "answer", minutes: "null"))) {
            XCTAssertEqual($0 as? MeetingMinutesError, .outcomeContradictsBody)
        }
    }

    func testInsufficientEvidenceCarryingMinutesIsRejected() {
        XCTAssertThrowsError(
            try MeetingMinutesParser.parse(reply(outcome: "insufficientEvidence", minutes: Self.sampleMinutes))) {
            XCTAssertEqual($0 as? MeetingMinutesError, .outcomeContradictsBody)
        }
    }

    func testAnotherPolicyVersionIsRejected() {
        XCTAssertThrowsError(
            try MeetingMinutesParser.parse(reply(outcome: "answer", minutes: Self.sampleMinutes, policy: "pet-log-context-v3"))) {
            XCTAssertEqual($0 as? MeetingMinutesError, .policyVersionMismatch("pet-log-context-v3"))
        }
    }

    func testProseInsteadOfJSONIsRejectedRatherThanShown() {
        XCTAssertThrowsError(try MeetingMinutesParser.parse("議事録を書きました。まず…")) {
            XCTAssertEqual($0 as? MeetingMinutesError, .notJSON)
        }
    }

    func testAFencedReplyStillParses() throws {
        let fenced = "```json\n" + reply(outcome: "answer", minutes: Self.sampleMinutes) + "\n```"
        XCTAssertEqual(try MeetingMinutesParser.parse(fenced)?.summary, "来週の段取りを決めた。")
    }

    // MARK: - Rendering

    func testMarkdownLeadsWithTheOwnersOwnActionItems() throws {
        let minutes = try XCTUnwrap(try MeetingMinutesParser.parse(reply(outcome: "answer", minutes: Self.sampleMinutes)))
        let md = minutes.markdown(record: record())
        let lines = md.components(separatedBy: "\n")
        let todo = lines.firstIndex { $0.hasPrefix("- [ ]") }
        XCTAssertEqual(lines[try XCTUnwrap(todo)], "- [ ] 日程を確定する（金曜） [seg-1]")
        XCTAssertTrue(md.hasPrefix("# Weekly sync"))
        XCTAssertTrue(md.contains("出席: 田中"))
        XCTAssertTrue(md.contains("欠席: 佐藤"))
        XCTAssertTrue(md.contains("## 決まったこと"))
    }

    func testMarkdownReadsTheClockOfTheMeetingsOwnZone() throws {
        let minutes = try XCTUnwrap(try MeetingMinutesParser.parse(reply(outcome: "answer", minutes: Self.sampleMinutes)))
        let kolkata = minutes.markdown(record: record(zone: "Asia/Kolkata"))
        let tokyo = minutes.markdown(record: record(zone: "Asia/Tokyo"))
        XCTAssertNotEqual(kolkata, tokyo)
        XCTAssertTrue(kolkata.contains("(Asia/Kolkata)"))
    }
}
