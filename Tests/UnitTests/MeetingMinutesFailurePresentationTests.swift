import XCTest
@testable import ClawGate

final class MeetingMinutesFailurePresentationTests: XCTestCase {
    func testInvalidEvidenceUsesCitationReasonAndKeepsRawDetailsOutOfSummary() {
        let raw = "invalidEvidence(claim: Optional(\"顧客は承認した\"), reason: \"evidence に引用がありません\") — 返答: {\"outcome\":\"answer\"}"

        let presentation = MeetingMinutesFailurePresentation.make(error: raw, state: "failed",
                                                                   completedParts: 1, totalParts: 2)

        XCTAssertEqual(presentation?.summary,
                       "引用の確認に失敗しました。議事録の根拠を確認できませんでした。 完成済みの 1 パートは残っています。 失敗した残りのパートだけ続きから作れます。")
        XCTAssertFalse(presentation?.summary.contains("invalidEvidence") == true)
        XCTAssertFalse(presentation?.summary.contains("outcome") == true)
        XCTAssertEqual(presentation?.technicalDetails, raw)
    }

    func testTimeoutAndUnknownFailureStayConcise() {
        let timeout = MeetingMinutesFailurePresentation.make(error: "request timed out after 30s", state: "failed",
                                                              completedParts: 0, totalParts: 1)
        XCTAssertEqual(timeout?.summary,
                       "生成が時間内に完了しませんでした。 自動再試行は行いません。必要なら「もう一度作る」を選んでください。")

        let generic = MeetingMinutesFailurePresentation.make(error: "unexpected backend response {\"raw\":true}", state: "failed",
                                                              completedParts: 0, totalParts: 1)
        XCTAssertEqual(generic?.summary,
                       "議事録の生成に失敗しました。 自動再試行は行いません。必要なら「もう一度作る」を選んでください。")
        XCTAssertFalse(generic?.summary.contains("backend") == true)
    }
}
