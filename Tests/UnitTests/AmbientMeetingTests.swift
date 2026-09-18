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
