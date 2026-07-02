import XCTest
@testable import ClawGate

/// Characterization tests for OpsLogSummarizer — the pure log-parsing/formatting
/// helpers extracted verbatim from MenuBarApp (TD-10). Expected values are
/// derived by reading the implementation, not by copying its runtime output.
/// This is the regression guard for the extraction: behavior must stay identical.
final class OpsLogSummarizerTests: XCTestCase {

    private func entry(event: String, message: String) -> OpsLogEntry {
        OpsLogEntry(
            ts: "", level: "info", event: event, role: "server",
            host: "example-host", script: "test", message: message
        )
    }

    // MARK: - parseKeyValueMessage

    func testParseKeyValueSplitsSpaceSeparatedPairs() {
        // "text=hello world": tokens split on space, so text's value is only
        // "hello"; the bare token "world" (no '=') is skipped.
        XCTAssertEqual(
            OpsLogSummarizer.parseKeyValueMessage("project=alpha bytes=128 text=hello world"),
            ["project": "alpha", "bytes": "128", "text": "hello"]
        )
    }

    func testParseKeyValueSkipsEmptyValueTokens() {
        XCTAssertEqual(OpsLogSummarizer.parseKeyValueMessage("key= project=beta"), ["project": "beta"])
    }

    func testParseKeyValueSkipsTokensWithoutEquals() {
        XCTAssertEqual(OpsLogSummarizer.parseKeyValueMessage("noeq project=gamma"), ["project": "gamma"])
    }

    func testParseKeyValueSkipsEmptyKeyTokens() {
        XCTAssertEqual(OpsLogSummarizer.parseKeyValueMessage("=orphan project=delta"), ["project": "delta"])
    }

    func testParseKeyValueDuplicateKeyLastWins() {
        XCTAssertEqual(OpsLogSummarizer.parseKeyValueMessage("a=1 a=2"), ["a": "2"])
    }

    func testParseKeyValueEmptyMessage() {
        XCTAssertEqual(OpsLogSummarizer.parseKeyValueMessage(""), [:])
    }

    // MARK: - parseMessageFields

    func testParseMessageFieldsTakesFullTextAfterTextMarker() {
        // Unlike parseKeyValueMessage, .text captures everything after "text=".
        let fields = OpsLogSummarizer.parseMessageFields("project=alpha bytes=128 text=hello world")
        XCTAssertEqual(fields.project, "alpha")
        XCTAssertEqual(fields.bytes, 128)
        XCTAssertEqual(fields.text, "hello world")
    }

    func testParseMessageFieldsNonNumericBytesIsNil() {
        let fields = OpsLogSummarizer.parseMessageFields("bytes=abc")
        XCTAssertNil(fields.project)
        XCTAssertNil(fields.bytes)
        XCTAssertEqual(fields.text, "")
    }

    func testParseMessageFieldsWithoutTextMarker() {
        let fields = OpsLogSummarizer.parseMessageFields("project=solo bytes=64")
        XCTAssertEqual(fields.project, "solo")
        XCTAssertEqual(fields.bytes, 64)
        XCTAssertEqual(fields.text, "")
    }

    func testParseMessageFieldsTrimsTextValue() {
        XCTAssertEqual(OpsLogSummarizer.parseMessageFields("text=  spaced   ").text, "spaced")
    }

    // MARK: - shortProject

    func testShortProjectNilAndEmptyBecomeDash() {
        XCTAssertEqual(OpsLogSummarizer.shortProject(nil), "-")
        XCTAssertEqual(OpsLogSummarizer.shortProject(""), "-")
        XCTAssertEqual(OpsLogSummarizer.shortProject("   "), "-")
    }

    func testShortProjectTrimsWhitespace() {
        XCTAssertEqual(OpsLogSummarizer.shortProject("  padded  "), "padded")
    }

    func testShortProjectTruncatesToSixteenChars() {
        XCTAssertEqual(OpsLogSummarizer.shortProject("abcdefghijklmnopqrst"), "abcdefghijklmnop")
    }

    // MARK: - humanReadableSummary (also exercises compactMessage indirectly)

    func testSummaryTmuxCaptureEvents() {
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "tmux.progress", message: "project=alpha bytes=128 text=doing work")),
            "CAP PROG alpha 128b doing work"
        )
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "tmux.completion", message: "project=beta bytes=64 text=done")),
            "CAP DONE beta 64b done"
        )
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "tmux.question", message: "project=gamma bytes=10 text=why")),
            "CAP Q gamma 10b why"
        )
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "tmux.forward", message: "project=delta bytes=5 text=fwd")),
            "FWD delta 5b fwd"
        )
    }

    func testSummaryMissingProjectAndBytesUseDashPlaceholders() {
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "tmux.progress", message: "text=only")),
            "CAP PROG - -b only"
        )
    }

    func testSummaryFixedLabelEvents() {
        XCTAssertEqual(OpsLogSummarizer.humanReadableSummary(for: entry(event: "tmux_gateway_deliver", message: "project=eps")), "ACK eps")
        XCTAssertEqual(OpsLogSummarizer.humanReadableSummary(for: entry(event: "line_send_ok", message: "ignored")), "MSG OUT OK")
        XCTAssertEqual(OpsLogSummarizer.humanReadableSummary(for: entry(event: "line_send_start", message: "ignored")), "MSG SEND")
        XCTAssertEqual(OpsLogSummarizer.humanReadableSummary(for: entry(event: "ingress_received", message: "ignored")), "SRV IN")
        XCTAssertEqual(OpsLogSummarizer.humanReadableSummary(for: entry(event: "ingress_validated", message: "ignored")), "SRV VALID")
    }

    func testSummarySendFailedParsesErrorFields() {
        // error_message value stops at the first space ("boom"), per parseKeyValueMessage.
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "send_failed", message: "project=alpha error_code=E1 error_message=boom now")),
            "ERR alpha E1 boom"
        )
    }

    func testSummarySendFailedDefaultsWhenErrorFieldsAbsent() {
        // No error_code -> "unknown"; empty error_message -> trailing space is current behavior.
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "send_failed", message: "project=z")),
            "ERR z unknown "
        )
    }

    func testSummaryFederationEvents() {
        XCTAssertEqual(OpsLogSummarizer.humanReadableSummary(for: entry(event: "federation.connected", message: "hi there")), "FED UP hi there")
        XCTAssertEqual(OpsLogSummarizer.humanReadableSummary(for: entry(event: "federation.connecting", message: "conn")), "FED CONNECT conn")
        XCTAssertEqual(OpsLogSummarizer.humanReadableSummary(for: entry(event: "federation.closed", message: "bye")), "FED CLOSED bye")
        XCTAssertEqual(OpsLogSummarizer.humanReadableSummary(for: entry(event: "federation.error", message: "oops")), "FED ERR oops")
        XCTAssertEqual(OpsLogSummarizer.humanReadableSummary(for: entry(event: "federation.disabled", message: "off")), "FED OFF off")
    }

    func testSummaryDefaultEventFallback() {
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "custom.event", message: "payload")),
            "custom.event payload"
        )
    }

    func testSummaryDefaultEventEmptyMessageReturnsEventOnly() {
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "custom.event", message: "")),
            "custom.event"
        )
    }

    func testSummaryCompactMessageReplacesNewlines() {
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "federation.connected", message: "line1\nline2")),
            "FED UP line1 line2"
        )
    }

    func testSummaryCompactMessageTruncatesOverBudget() {
        // federation.connected caps at 32 chars: prefix(32) + "..."
        let long = String(repeating: "x", count: 40)
        let expected = "FED UP " + String(repeating: "x", count: 32) + "..."
        XCTAssertEqual(
            OpsLogSummarizer.humanReadableSummary(for: entry(event: "federation.connected", message: long)),
            expected
        )
    }
}
