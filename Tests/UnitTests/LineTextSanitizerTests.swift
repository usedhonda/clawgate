import XCTest
@testable import ClawGate

final class LineTextSanitizerTests: XCTestCase {
    func testSanitizeRemovesStandaloneUIArtifacts() {
        for body in ["これは本文", "Hello from user"] {
            let text = "既読\n12:34\n\(body)"
            XCTAssertEqual(LineTextSanitizer.sanitize(text), body)
        }
    }

    func testSanitizeKeepsLongMessage() {
        for text in [
            "これは非常に長い本文です。途中に既読という単語が含まれていても削除しません。",
            "メッセージ送信時刻は12:34で、既読がつきました。長い本文なので削除されません。",
        ] {
            XCTAssertEqual(LineTextSanitizer.sanitize(text), text)
        }
    }

    func testEchoNormalizationMatchesAcrossWhitespace() {
        let cases = [
            ("long command with args --foo=bar --baz=qux", "long command\nwith args --foo=bar\n--baz=qux"),
            ("[clawgate.cc] long message with multiple lines of text for testing", "[clawgate.cc] long message\nwith multiple lines of\ntext for testing"),
        ]
        for (sent, candidate) in cases {
            XCTAssertTrue(LineTextSanitizer.textLikelyContainsSentText(candidate: candidate, sentText: sent))
        }
    }
}
