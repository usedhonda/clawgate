import XCTest
@testable import ClawGate

/// LINE renders a timestamp and a read receipt beside every bubble as separate
/// OCR observations. An inbound bubble is white, so its row never reaches the
/// green outgoing mask and its timestamp survives preprocessing on every frame.
///
/// On 2026-08-28 a frame whose only surviving observation was such a timestamp
/// was delivered as an inbound message: "午前 10:05" came back from OCR as
/// "千別 10:0" and reached the user as an appointment nobody had made.
final class VisionOCRChromeLabelTests: XCTestCase {

    // MARK: - Chrome

    func testTimestampBesideBubbleIsChrome() {
        XCTAssertTrue(VisionOCR.isChromeLabel("午前 10:12"))
        XCTAssertTrue(VisionOCR.isChromeLabel("午後12:17"))
        XCTAssertTrue(VisionOCR.isChromeLabel("10:05"))
    }

    /// The observed garble from the incident. Matching the rendered wording
    /// would miss this one, which is why the test is structural.
    func testGarbledTimestampIsStillChrome() {
        XCTAssertTrue(VisionOCR.isChromeLabel("千別 10:0|"))
        XCTAssertTrue(VisionOCR.isChromeLabel("千別 10:0"))
    }

    func testFullWidthColonIsStillAClock() {
        XCTAssertTrue(VisionOCR.isChromeLabel("午前 10：12"))
    }

    func testReadReceiptIsChrome() {
        XCTAssertTrue(VisionOCR.isChromeLabel("既読"))
        XCTAssertTrue(VisionOCR.isChromeLabel("既読 3"))
    }

    func testEmptyObservationIsChrome() {
        XCTAssertTrue(VisionOCR.isChromeLabel(""))
        XCTAssertTrue(VisionOCR.isChromeLabel("   \n "))
    }

    // MARK: - Messages

    /// A clock inside a sentence lives in the sentence's own observation, so it
    /// is never seen by this test in isolation -- but guard it anyway, because
    /// dropping a real appointment is the failure this fix must not cause.
    func testTimeInsideASentenceIsAMessage() {
        XCTAssertFalse(VisionOCR.isChromeLabel("10:30に行くね"))
        XCTAssertFalse(VisionOCR.isChromeLabel("18:00から打ち合わせが入っています"))
    }

    /// Short replies carry fewer letters than the chrome threshold and must
    /// survive on the absence of a clock alone.
    func testShortReplyIsAMessage() {
        XCTAssertFalse(VisionOCR.isChromeLabel("はい"))
        XCTAssertFalse(VisionOCR.isChromeLabel("OK"))
        XCTAssertFalse(VisionOCR.isChromeLabel("ありがとう"))
    }

    func testProseIsAMessage() {
        XCTAssertFalse(
            VisionOCR.isChromeLabel("画像の読み取りではなく、自分で書いた文字を読もうとしているだけだね。")
        )
    }

    // MARK: - Whole frames

    /// The healthy frame measured on Host A: one real message plus the
    /// timestamp rendered to its right. The timestamp must not be delivered.
    func testFrameKeepsBodyAndDropsItsTimestamp() {
        let body = VisionOCR.inboundBody(fromObservedTexts: [
            "画像の読み取りではなく、自分で書いた文字を読もうとしているだけだね。",
            "午前 10:12",
        ])
        XCTAssertEqual(body, "画像の読み取りではなく、自分で書いた文字を読もうとしているだけだね。")
    }

    /// The incident frame. A clock on its own is not a message, so nothing at
    /// all should leave the watcher.
    func testFrameOfNothingButAClockIsNotAMessage() {
        XCTAssertNil(VisionOCR.inboundBody(fromObservedTexts: ["千別 10:0|"]))
    }

    func testFrameOfNothingButChromeIsNotAMessage() {
        XCTAssertNil(VisionOCR.inboundBody(fromObservedTexts: ["既読", "午前 10:05", "午後12:17"]))
    }

    func testEmptyFrameIsNotAMessage() {
        XCTAssertNil(VisionOCR.inboundBody(fromObservedTexts: []))
    }

    func testMultipleBodiesKeepTheirOrder() {
        let body = VisionOCR.inboundBody(fromObservedTexts: [
            "既読",
            "おはよう",
            "午前 10:05",
            "今日は18:00から予定が入ってるよ",
        ])
        XCTAssertEqual(body, "おはよう\n今日は18:00から予定が入ってるよ")
    }
}
