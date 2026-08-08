import XCTest
@testable import ClawGate

/// D59 PRIMARY guard (runtime): the transport response log formatter must reduce
/// every wire-controlled field to bounded structural metadata — no sentinel
/// content (error message body, injected response id / payload type / error
/// code) may appear in the produced line.
final class TransportLogPrivacyTests: XCTestCase {
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
        // Unknown id → length only; unknown type → length only; unbounded code → length.
        XCTAssertTrue(line.contains("idLen="))
        XCTAssertTrue(line.contains("typeLen="))
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

    func testBoundedErrorCodeLoggedVerbatimButLongOneLengthOnly() {
        let short = TransportLog.responseLine(ok: false, responseId: "x", known: false,
                                              payloadType: nil, error: IncomingError(code: "serverError", message: "m"))
        XCTAssertTrue(short.contains("errCode=serverError"), "a short structural code is safe verbatim")

        let long = TransportLog.responseLine(ok: false, responseId: "x", known: false,
                                             payloadType: nil, error: IncomingError(code: String(repeating: "q", count: 80), message: "m"))
        XCTAssertFalse(long.contains(String(repeating: "q", count: 80)), "an over-long code is reduced to length")
    }
}
