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

    func testEvidenceMustResolveToInputSegment() {
        XCTAssertThrowsError(try MeetingMinutesParser.parse(
            reply(outcome: "answer", minutes: Self.sampleMinutes),
            validSegmentIds: ["seg-2"])) {
            XCTAssertEqual($0 as? MeetingMinutesError, .invalidEvidence)
        }
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
