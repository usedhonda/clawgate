import XCTest
@testable import ClawGate

final class AmbientTests: XCTestCase {

    // Role is resolved from the Gateway relationship: server hosts the Gateway
    // locally (localhost), client points at a remote Gateway. Default openclawHost
    // is localhost, so an unconfigured host resolves to server (fail-closed:
    // ambient stays OFF until explicitly pointed at a remote Gateway).
    func testRuntimeRoleFromGatewayRelationship() {
        var cfg = AppConfig.default
        XCTAssertEqual(cfg.runtimeRole, .server)
        XCTAssertFalse(cfg.isClientRole)

        for local in ["127.0.0.1", "localhost", "::1", "0.0.0.0", ""] {
            cfg.openclawHost = local
            XCTAssertEqual(cfg.runtimeRole, .server, "host \(local) should resolve to server")
        }

        cfg.openclawHost = "gateway-host.example-tailnet.ts.net"
        XCTAssertEqual(cfg.runtimeRole, .client)
        XCTAssertTrue(cfg.isClientRole)
    }

    func testTranscriberParsesWhisperJSON() throws {
        let json = """
        {"transcription":[
          {"offsets":{"from":0,"to":2240},"text":" Clawgate ambient transcription test."},
          {"offsets":{"from":2540,"to":3880},"text":" The brass fox is awake."}
        ]}
        """.data(using: .utf8)!
        let segs = try AmbientTranscriber.parse(json)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(segs[0].endSeconds, 2.24, accuracy: 0.001)
        XCTAssertEqual(segs[0].text, "Clawgate ambient transcription test.")
        XCTAssertEqual(segs[1].startSeconds, 2.54, accuracy: 0.001)
        XCTAssertEqual(segs[1].text, "The brass fox is awake.")
    }

    func testClassifyDropsConsecutiveDuplicates() {
        let segs = [
            TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "hello"),
            TranscriptSegment(startSeconds: 1, endSeconds: 2, text: "hello"),
            TranscriptSegment(startSeconds: 2, endSeconds: 3, text: "world"),
        ]
        let r = AmbientTranscriber.classify(segs)
        XCTAssertEqual(r.kept.map(\.text), ["hello", "world"])
        XCTAssertEqual(r.skipped.map(\.reason), ["immediate_duplicate"])
    }

    func testClassifyFlagsInternalRepetition() {
        XCTAssertTrue(AmbientTranscriber.isInternalRepetition("yeah yeah yeah yeah"))
        XCTAssertFalse(AmbientTranscriber.isInternalRepetition("the brass fox is awake"))
        XCTAssertFalse(AmbientTranscriber.isInternalRepetition("yeah yeah"))

        let segs = [TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "yeah yeah yeah yeah")]
        let r = AmbientTranscriber.classify(segs)
        XCTAssertTrue(r.kept.isEmpty)
        XCTAssertEqual(r.skipped.map(\.reason), ["internal_repetition"])
    }

    func testStorageDefaultWhisperPathsUnderApplicationSupport() {
        XCTAssertTrue(AmbientStorage.defaultWhisperBinary.path.hasSuffix("ClawGate/whisper/bin/whisper-cli"))
        XCTAssertTrue(AmbientStorage.defaultWhisperModel.path.hasSuffix("ClawGate/whisper/models/ggml-large-v3-turbo.bin"))
    }
}
