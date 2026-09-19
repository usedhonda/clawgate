import XCTest
@testable import ClawGate

/// Google Meet second stream: echo suppression for the Mac's speakers and
/// speech-time ordering of the two streams. Pure functions only -- nothing here
/// touches ambient storage or a controller.
final class AmbientMeetingTests: XCTestCase {
    private func seg(_ text: String, at: Double?) -> TranscriptSegment {
        var s = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: text)
        s.capturedAt = at
        return s
    }

    func testMicRepeatOfRecentChromeLineIsEcho() {
        let system = [seg("来週の打ち合わせは火曜日でどうですか", at: 1000)]
        XCTAssertTrue(AmbientController.isMeetingEcho(seg("来週の打ち合わせは火曜でどうですか", at: 1002), against: system))
    }

    func testOwnerReplyIsNotEcho() {
        let system = [seg("来週の打ち合わせは火曜日でどうですか", at: 1000)]
        XCTAssertFalse(AmbientController.isMeetingEcho(seg("火曜は無理なので水曜でお願いします", at: 1004), against: system))
    }

    func testSameTextOutsideWindowIsNotEcho() {
        let system = [seg("了解しました", at: 1000)]
        XCTAssertFalse(AmbientController.isMeetingEcho(seg("了解しました", at: 1030), against: system))
    }

    func testUndatedMicSegmentIsNeverDropped() {
        let system = [seg("了解しました", at: 1000)]
        XCTAssertFalse(AmbientController.isMeetingEcho(seg("了解しました", at: nil), against: system))
    }

    func testSimilarityBounds() {
        XCTAssertEqual(AmbientController.similarity("abc", "abc"), 1)
        XCTAssertEqual(AmbientController.similarity("abc", "xyz"), 0)
        XCTAssertEqual(AmbientController.similarity("", ""), 1)
    }

    func testLinesAreOrderedBySpeechTimeAcrossStreams() {
        typealias Line = AmbientIngestProducer.Line
        let t = Date(timeIntervalSince1970: 1_000)
        // Mic chunk arrives first, Chrome chunk for the same period arrives later.
        let lines = [
            Line(text: "わかりました", speaker: "self", capturedAt: t.addingTimeInterval(20)),
            Line(text: "それでは始めます", speaker: "self", capturedAt: t.addingTimeInterval(40)),
            Line(text: "資料を共有しますね", speaker: "other", capturedAt: t.addingTimeInterval(10)),
            Line(text: "見えていますか", speaker: "other", capturedAt: t.addingTimeInterval(30)),
        ]
        let ordered = AmbientIngestProducer.orderedBySpeechTime(lines).map(\.text)
        XCTAssertEqual(ordered, ["資料を共有しますね", "わかりました", "見えていますか", "それでは始めます"])
    }

    // MARK: - Context carried across chunks

    func testPromptAppendsOnlyTheTailOfThePreviousChunk() {
        let long = String(repeating: "あ", count: 200) + "最後の言葉"
        let prompt = AmbientTranscriber.prompt(base: "BASE", context: long)
        XCTAssertTrue(prompt.hasPrefix("BASE\n"))
        XCTAssertTrue(prompt.hasSuffix("最後の言葉"))
        XCTAssertEqual(prompt.count, "BASE\n".count + 120)
    }

    func testNoContextLeavesTheBasePrompt() {
        XCTAssertEqual(AmbientTranscriber.prompt(base: "BASE", context: nil), "BASE")
        XCTAssertEqual(AmbientTranscriber.prompt(base: "BASE", context: "  "), "BASE")
    }

    // MARK: - Speaker attribution from Meet's speaking tiles

    private typealias Interval = AmbientController.SpeakerInterval

    func testSingleClearSpeakerIsNamed() {
        let intervals = [Interval(name: "田中", start: 100, end: 110)]
        XCTAssertEqual(AmbientController.attributeSpeaker(start: 101, end: 105, intervals: intervals, now: 200), "田中")
    }

    func testTwoOverlappingSpeakersStayUnnamed() {
        let intervals = [Interval(name: "田中", start: 100, end: 110), Interval(name: "佐藤", start: 102, end: 108)]
        XCTAssertNil(AmbientController.attributeSpeaker(start: 101, end: 105, intervals: intervals, now: 200))
    }

    func testNobodyLitStaysUnnamed() {
        XCTAssertNil(AmbientController.attributeSpeaker(start: 101, end: 105, intervals: [], now: 200))
    }

    func testWeakOverlapStaysUnnamed() {
        let intervals = [Interval(name: "田中", start: 104, end: 110)]   // covers 1s of a 4s line
        XCTAssertNil(AmbientController.attributeSpeaker(start: 101, end: 105, intervals: intervals, now: 200))
    }

    func testOpenIntervalCountsUpToNow() {
        let intervals = [Interval(name: "田中", start: 100, end: nil)]
        XCTAssertEqual(AmbientController.attributeSpeaker(start: 101, end: 105, intervals: intervals, now: 106), "田中")
    }

    func testSummaryShowsParticipantNamesAndSplitsByName() {
        typealias Line = AmbientIngestProducer.Line
        let t = Date(timeIntervalSince1970: 1_000)
        let lines = [
            Line(text: "資料を共有します", speaker: "other", capturedAt: t, speakerName: "田中"),
            Line(text: "見えています", speaker: "other", capturedAt: t.addingTimeInterval(5), speakerName: "佐藤"),
            Line(text: "よろしく", speaker: "other", capturedAt: t.addingTimeInterval(8), speakerName: nil),
        ]
        let summary = AmbientIngestProducer.dialogueSummary(lines, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(summary.components(separatedBy: "\n"), [
            "[00:16] 田中: 資料を共有します",
            "[00:16] 佐藤: 見えています",
            "[00:16] 相手: よろしく",
        ])
    }

    func testUndatedLineKeepsItsArrivalPosition() {
        typealias Line = AmbientIngestProducer.Line
        let t = Date(timeIntervalSince1970: 1_000)
        let lines = [
            Line(text: "a", speaker: nil, capturedAt: t),
            Line(text: "b", speaker: nil, capturedAt: nil),
            Line(text: "c", speaker: nil, capturedAt: t.addingTimeInterval(5)),
        ]
        XCTAssertEqual(AmbientIngestProducer.orderedBySpeechTime(lines).map(\.text), ["a", "b", "c"])
    }
}
