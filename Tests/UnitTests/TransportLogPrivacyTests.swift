import XCTest
@testable import ClawGate

/// D59 guards. The PRIMARY guard drives the real `handleResponse` callsite
/// through an injectable sink and inspects exactly what ships — so a future raw
/// log added to the emit path (String(describing:), payload dumps, etc.) is
/// caught, not just the pure formatter. The pure-function and source-scan checks
/// are AUXILIARY.
final class TransportLogPrivacyTests: XCTestCase {
    override func tearDown() {
        OpenClawWSClient.transportLogSinkForTesting = nil
        super.tearDown()
    }

    private final class LineBox: @unchecked Sendable { var lines: [String] = [] }

    /// PRIMARY: a sentinel-laden response driven through the actual
    /// handleResponse callsite must emit a line with zero wire content.
    func testHandleResponseCallsiteEmitsOnlyBoundedMetadata() async {
        let box = LineBox()
        OpenClawWSClient.transportLogSinkForTesting = { box.lines.append($0) }

        let json = """
        {"type":"resp","id":"SENTINELID-\(String(repeating: "x", count: 200))","ok":false,
         "payload":{"type":"evil.SENTINELTYPE.injected"},
         "error":{"code":"SENTINELCODE with spaces 秘密","message":"SENTINELMSG hidden instruction 機密"}}
        """
        let msg = try! JSONDecoder().decode(IncomingMessage.self, from: Data(json.utf8))
        let client = OpenClawWSClient()
        await client.handleResponseForTesting(msg)

        XCTAssertEqual(box.lines.count, 1, "the callsite must emit exactly one response log line")
        let line = box.lines.first ?? ""
        for sentinel in ["SENTINELID", "SENTINELTYPE", "SENTINELCODE", "SENTINELMSG", "秘密", "機密"] {
            XCTAssertFalse(line.contains(sentinel), "wire content '\(sentinel)' leaked from the callsite: \(line)")
        }
    }

    // MARK: - Auxiliary pure-formatter checks

    func testResponseLineNeverEchoesWireControlledContent() {
        let sentinelId = "SENTINELID-" + String(repeating: "x", count: 200)
        let sentinelType = "evil.type.SENTINELTYPE.injected"
        let err = IncomingError(code: "SENTINELCODE with spaces 秘密",
                                message: "SENTINELMSG hidden instruction 機密 " + String(repeating: "z", count: 500))
        let line = TransportLog.responseLine(ok: false, responseId: sentinelId, known: false,
                                             payloadType: sentinelType, error: err)
        for sentinel in ["SENTINELID", "SENTINELTYPE", "SENTINELCODE", "SENTINELMSG", "秘密", "機密"] {
            XCTAssertFalse(line.contains(sentinel), "wire content '\(sentinel)' leaked: \(line)")
        }
        // Unknown id/type/code → bounded hash tag; message → length only.
        XCTAssertTrue(line.contains("idTag=h"))
        XCTAssertTrue(line.contains("typeTag=h"))
        XCTAssertTrue(line.contains("codeTag=h"))
        XCTAssertTrue(line.contains("errMsgLen="))
    }

    func testResponseLineKeepsBoundedTokensForOurOwnFields() {
        let ourId = "A1B2C3D4-5566-7788-99AA-BBCCDDEEFF00"  // our generated UUID
        let line = TransportLog.responseLine(ok: true, responseId: ourId, known: true,
                                             payloadType: "hello-ok", error: nil)
        XCTAssertTrue(line.contains("id=A1B2C3D4"), "a known (our own) id logs a short prefix")
        XCTAssertFalse(line.contains(ourId), "never the full id")
        XCTAssertTrue(line.contains("type=hello-ok"), "an allowlisted protocol type logs verbatim")
        XCTAssertTrue(line.contains("err=none"))
    }

    func testAllowlistedErrorCodeVerbatimUnknownHashed() {
        let known = TransportLog.responseLine(ok: false, responseId: "x", known: false,
                                              payloadType: nil, error: IncomingError(code: "serverError", message: "m"))
        XCTAssertTrue(known.contains("errCode=serverError"), "an allowlisted code is safe verbatim")

        // An unknown code — even a short one that could carry a secret — is
        // hashed, never printed raw.
        let secretCode = "sk-abcd1234"
        let unknown = TransportLog.responseLine(ok: false, responseId: "x", known: false,
                                                payloadType: nil, error: IncomingError(code: secretCode, message: "m"))
        XCTAssertFalse(unknown.contains(secretCode), "an unknown code must be hashed, never raw")
        XCTAssertTrue(unknown.contains("codeTag=h"))
    }
}
