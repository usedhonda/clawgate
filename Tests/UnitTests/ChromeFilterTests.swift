import XCTest
@testable import ClawGate

final class ChromeFilterTests: XCTestCase {
    func testTimestampIsChrome() {
        XCTAssertTrue(LINEAdapter.isUIChrome("12:34", windowTitle: nil))
        XCTAssertTrue(LINEAdapter.isUIChrome("9:05", windowTitle: nil))
        XCTAssertTrue(LINEAdapter.isUIChrome("12:34:56", windowTitle: nil))
    }

    func testDateIsChrome() {
        XCTAssertTrue(LINEAdapter.isUIChrome("2026/2/6", windowTitle: nil))
        XCTAssertTrue(LINEAdapter.isUIChrome("2026-02-06", windowTitle: nil))
    }

    func testWeekdayIsChrome() {
        XCTAssertTrue(LINEAdapter.isUIChrome("月曜日", windowTitle: nil))
        XCTAssertTrue(LINEAdapter.isUIChrome("金曜", windowTitle: nil))
    }

    func testMessageTextIsNotChrome() {
        XCTAssertFalse(LINEAdapter.isUIChrome("こんにちは", windowTitle: nil))
        XCTAssertFalse(LINEAdapter.isUIChrome("Hello world", windowTitle: nil))
        XCTAssertFalse(LINEAdapter.isUIChrome("お疲れ様です", windowTitle: nil))
    }

    func testDigitsOnlyIsChrome() {
        XCTAssertTrue(LINEAdapter.isUIChrome("3", windowTitle: nil))
        XCTAssertTrue(LINEAdapter.isUIChrome("42", windowTitle: nil))
    }

    func testSingleCharIsChrome() {
        XCTAssertTrue(LINEAdapter.isUIChrome("A", windowTitle: nil))
        XCTAssertTrue(LINEAdapter.isUIChrome("あ", windowTitle: nil))
    }

    func testWindowTitleIsChrome() {
        XCTAssertTrue(LINEAdapter.isUIChrome("田中太郎", windowTitle: "田中太郎"))
        XCTAssertFalse(LINEAdapter.isUIChrome("田中太郎", windowTitle: "佐藤花子"))
    }

    func testAMPMIsChrome() {
        XCTAssertTrue(LINEAdapter.isUIChrome("AM", windowTitle: nil))
        XCTAssertTrue(LINEAdapter.isUIChrome("PM", windowTitle: nil))
    }

    func testYesterdayIsChrome() {
        XCTAssertTrue(LINEAdapter.isUIChrome("yesterday", windowTitle: nil))
        XCTAssertTrue(LINEAdapter.isUIChrome("今日", windowTitle: nil))
        XCTAssertTrue(LINEAdapter.isUIChrome("昨日", windowTitle: nil))
    }
}
