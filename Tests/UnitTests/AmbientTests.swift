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

    // MARK: - ambient.ingest L1 producer (privacy + schema)

    func testIngestSummaryContainsNoVerbatimTranscript() {
        let segments = [
            "We should ship the release on Thursday after the review meeting.",
            "The release branch still has two failing integration tests today.",
            "Let me check the release pipeline before the meeting starts.",
        ]
        let params = AmbientIngestProducer.buildParams(
            segmentTexts: segments,
            windowStart: Date(timeIntervalSince1970: 1_700_000_000),
            windowEnd: Date(timeIntervalSince1970: 1_700_000_060),
            sessionID: "ctx-test",
            sourceSeq: 1,
            now: Date(timeIntervalSince1970: 1_700_000_061)
        )
        // Contract: summary is processed, never a verbatim transcript sentence.
        for s in segments {
            XCTAssertFalse(params.state.summary.contains(s), "summary leaked verbatim segment: \(s)")
        }
        XCTAssertFalse(params.state.summary.isEmpty)
        // Phase 1 sends no people hints at all (default redact, no diarization).
        XCTAssertTrue(params.state.peopleHintRedacted.isEmpty)
        XCTAssertNil(params.state.placeHint)
    }

    func testIngestParamsSchemaShape() throws {
        let params = AmbientIngestProducer.buildParams(
            segmentTexts: ["release planning discussion", "release timing details"],
            windowStart: Date(timeIntervalSince1970: 1_700_000_000),
            windowEnd: Date(timeIntervalSince1970: 1_700_000_060),
            sessionID: "ctx-test",
            sourceSeq: 42,
            now: Date(timeIntervalSince1970: 1_700_000_061)
        )
        XCTAssertEqual(params.source, "clawgate_ambient")
        XCTAssertEqual(params.captureMode, "ambient")
        XCTAssertEqual(params.latencyClass, "near-realtime")
        XCTAssertEqual(params.sourceSeq, 42)
        XCTAssertEqual(params.sourceIds, ["ctx-test"])
        XCTAssertGreaterThan(params.state.staleAfter, params.state.updatedAt)
        XCTAssertEqual(params.state.sources.count, 1)
        XCTAssertEqual(params.state.sources[0].source, "clawgate_ambient")
        XCTAssertTrue((0.0...1.0).contains(params.confidence))

        let data = try JSONEncoder().encode(params)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["state"])
        XCTAssertNotNil(json["sourceWindow"])
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        XCTAssertNotNil(state["summary"])
        // Optionals that are nil must be omitted, not null-encoded.
        XCTAssertNil(state["placeHint"])
    }

    func testOpaqueDeviceIDIsStableAndHostnameFree() {
        let a = AmbientIngestProducer.opaqueDeviceID()
        let b = AmbientIngestProducer.opaqueDeviceID()
        XCTAssertEqual(a, b, "device id must be stable across calls")
        XCTAssertTrue(a.hasPrefix("cg-"))
        XCTAssertEqual(a.count, 19)  // "cg-" + 16 hex chars
        let host = ProcessInfo.processInfo.hostName.lowercased()
        if host.count >= 4 {
            XCTAssertFalse(a.lowercased().contains(host), "device id must not embed the hostname")
        }
    }

    func testRecurringKeywordsRequireRecurrence() {
        // Words appearing once must not become keywords (reduces quote risk).
        let texts = ["alpha bravo charlie", "delta echo foxtrot"]
        XCTAssertTrue(AmbientIngestProducer.recurringKeywords(in: texts).isEmpty)
    }
}
