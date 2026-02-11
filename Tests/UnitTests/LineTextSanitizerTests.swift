import XCTest
@testable import ClawGate

final class LineTextSanitizerTests: XCTestCase {
    func testSanitizeRemovesStandaloneUIArtifacts() {
        let text = """
        既読
        12:34
        これは本文
        """
        XCTAssertEqual(LineTextSanitizer.sanitize(text), "これは本文")
    }

    func testSanitizeKeepsLongMessage() {
        let text = """
        これは非常に長い本文です。途中に既読という単語が含まれていても削除しません。
        """
        XCTAssertEqual(LineTextSanitizer.sanitize(text), text)
    }

    func testEchoNormalizationMatchesAcrossWhitespace() {
        let sent = "long command with args --foo=bar --baz=qux"
        let candidate = "long command\nwith args --foo=bar\n--baz=qux"
        XCTAssertTrue(LineTextSanitizer.textLikelyContainsSentText(candidate: candidate, sentText: sent))
    }
}
