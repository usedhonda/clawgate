import XCTest
@testable import ClawGate

/// A multi-part generation joined each part's "この記録範囲では…" overview
/// into one paragraph that repeated itself (2026-09-29). The rewrite pass may
/// replace only the overview and due dates, and only with grounded sentences.
final class MeetingMinutesSummaryPassTests: XCTestCase {
    private func part(_ summary: String, ids: [String]) -> MeetingMinutes {
        MeetingMinutes(title: "t", summary: summary,
                       topics: [MeetingTopic(heading: "議題", points: ["点"])], decisions: ["決定"],
                       actionItems: [MeetingActionItem(what: "資料を作る", owner: "A", due: "1日の昼ごろ", mine: false)],
                       openQuestions: [], evidence: [MeetingEvidence(claim: summary, segmentIds: ids),
                                                     MeetingEvidence(claim: "点", segmentIds: ["seg-9"])],
                       attendance: nil, language: "ja")
    }

    private var record: MeetingRecord {
        MeetingRecord(id: "m", source: "meet", startedAt: 1_790_650_000, endedAt: 1_790_653_600,
                      timeZone: "Asia/Singapore", title: "t", conferenceCode: nil, participants: [],
                      minutesState: "ready", minutesError: nil)
    }

    func testRewriteReplacesOnlyOverviewAndDue() throws {
        let parts = [part("この記録範囲では、出資が議論された。", ids: ["seg-1"]),
                     part("この記録範囲では、協業が議論された。", ids: ["seg-2"])]
        let joined = try XCTUnwrap(MeetingMinutes.combining(parts))
        let input = MeetingMinutesSummaryPass.input(for: joined, parts: parts, record: record)
        XCTAssertEqual(input.partSummaries.map(\.segmentIds), [["seg-1"], ["seg-2"]])
        let reply = try MeetingMinutesSummaryPass.parse("""
        {"policyVersion":"\(MeetingMinutesSummaryPass.policyVersion)","summary":"出資と協業の分け方が議論された。",
         "summaryEvidence":[{"claim":"出資と協業の分け方が議論された。","segmentIds":["seg-1","seg-2"]}],
         "dues":[{"index":0,"due":"10月1日 12:00"}]}
        """, input: input)
        let rewritten = MeetingMinutesSummaryPass.apply(reply, to: joined, parts: parts)
        XCTAssertEqual(rewritten.summary, "出資と協業の分け方が議論された。")
        XCTAssertEqual(rewritten.topics, joined.topics)
        XCTAssertEqual(rewritten.actionItems.first?.due, "10月1日 12:00")
        XCTAssertFalse(rewritten.evidence?.contains { $0.claim.hasPrefix("この記録範囲では") } ?? true)
        XCTAssertTrue(rewritten.evidence?.contains { $0.claim == "点" } ?? false)
    }

    func testOverviewCitingSegmentsOutsideThePartOverviewsIsRejected() throws {
        let parts = [part("この記録範囲では、出資が議論された。", ids: ["seg-1"]),
                     part("この記録範囲では、協業が議論された。", ids: ["seg-2"])]
        let joined = try XCTUnwrap(MeetingMinutes.combining(parts))
        let input = MeetingMinutesSummaryPass.input(for: joined, parts: parts, record: record)
        XCTAssertThrowsError(try MeetingMinutesSummaryPass.parse("""
        {"policyVersion":"\(MeetingMinutesSummaryPass.policyVersion)","summary":"新しい事実が語られた。",
         "summaryEvidence":[{"claim":"新しい事実が語られた。","segmentIds":["seg-99"]}]}
        """, input: input))
    }
}
