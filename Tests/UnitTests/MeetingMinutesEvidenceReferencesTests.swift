import XCTest
@testable import ClawGate

final class MeetingMinutesEvidenceReferencesTests: XCTestCase {
    private let policy = MeetingMinutesPrompt.policyVersion

    private func body(evidence: String) -> String {
        """
        {"outcome":"answer","contextDecision":{"policyVersion":"\(policy)"},"minutes":{"title":"t","summary":"会議全体の重要な概要と背景を確認して来週の具体的な段取りを決めた。","topics":[{"heading":"議題","points":["移行計画について具体的な日程と担当者を詳細に確認した"]}],"decisions":["火曜日の午後までに新しい運用を開始することを正式に決定した"],"actionItems":[{"what":"関係者全員へ最終資料を送付して確認を依頼する","owner":null,"due":null,"mine":false}],"openQuestions":["二週目以降の担当者と具体的な分担は未解決のままである"],"evidence":[\(evidence)],"attendance":null,"language":"ja"}}
        """
    }

    func testEverySupportedClaimReferenceExpandsToDurableClaim() throws {
        let refs = #"{"claimRef":"summary/0","segmentIds":["seg-1"]},{"claimRef":"topics/0/points/0","segmentIds":["seg-1"]},{"claimRef":"decisions/0","segmentIds":["seg-1"]},{"claimRef":"actionItems/0/what","segmentIds":["seg-1"]},{"claimRef":"openQuestions/0","segmentIds":["seg-1"]}"#
        let parsed = try XCTUnwrap(MeetingMinutesParser.parse(body(evidence: refs), validSegmentIds: ["seg-1"]))
        XCTAssertEqual(parsed.evidence?.map(\.claim), ["会議全体の重要な概要と背景を確認して来週の具体的な段取りを決めた。", "移行計画について具体的な日程と担当者を詳細に確認した", "火曜日の午後までに新しい運用を開始することを正式に決定した", "関係者全員へ最終資料を送付して確認を依頼する", "二週目以降の担当者と具体的な分担は未解決のままである"])
        XCTAssertTrue(parsed.evidence?.allSatisfy { $0.claimRef == nil } == true)
    }

    func testUnsupportedOutOfRangeAndMissingReferencesFailClosed() {
        for evidence in [
            #"{"claimRef":"summary/1","segmentIds":["seg-1"]}"#,
            #"{"claimRef":"summary/0/nope","segmentIds":["seg-1"]}"#,
            #"{"claimRef":"summary//0","segmentIds":["seg-1"]}"#,
            #"{"claimRef":"/summary/0","segmentIds":["seg-1"]}"#,
            #"{"segmentIds":["seg-1"]}"#
        ] {
            XCTAssertThrowsError(try MeetingMinutesParser.parse(body(evidence: evidence), validSegmentIds: ["seg-1"]))
        }
    }

    func testConflictingClaimAndReferenceFails() {
        let evidence = #"{"claim":"別の主張","claimRef":"summary/0","segmentIds":["seg-1"]}"#
        XCTAssertThrowsError(try MeetingMinutesParser.parse(body(evidence: evidence), validSegmentIds: ["seg-1"]))
    }

    func testLegacyClaimOnlyAndReferenceReplyPersistIdenticallyAndReferenceIsShorter() throws {
        let legacy = #"{"claim":"会議全体の重要な概要と背景を確認して来週の具体的な段取りを決めた。","segmentIds":["seg-1"]},{"claim":"移行計画について具体的な日程と担当者を詳細に確認した","segmentIds":["seg-1"]},{"claim":"火曜日の午後までに新しい運用を開始することを正式に決定した","segmentIds":["seg-1"]},{"claim":"関係者全員へ最終資料を送付して確認を依頼する","segmentIds":["seg-1"]},{"claim":"二週目以降の担当者と具体的な分担は未解決のままである","segmentIds":["seg-1"]}"#
        let refs = #"{"claimRef":"summary/0","segmentIds":["seg-1"]},{"claimRef":"topics/0/points/0","segmentIds":["seg-1"]},{"claimRef":"decisions/0","segmentIds":["seg-1"]},{"claimRef":"actionItems/0/what","segmentIds":["seg-1"]},{"claimRef":"openQuestions/0","segmentIds":["seg-1"]}"#
        let old = try XCTUnwrap(MeetingMinutesParser.parse(body(evidence: legacy), validSegmentIds: ["seg-1"]))
        let compact = try XCTUnwrap(MeetingMinutesParser.parse(body(evidence: refs), validSegmentIds: ["seg-1"]))
        XCTAssertEqual(old, compact)
        XCTAssertLessThan(body(evidence: refs).utf8.count, body(evidence: legacy).utf8.count)
    }
}
