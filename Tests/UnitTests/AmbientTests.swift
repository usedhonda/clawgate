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

    // MARK: - Hallucination filters (shapes from the real 2026-06-10 session)

    func testClassifyDropsZeroDurationBoundaryFillers() {
        let segs = [
            TranscriptSegment(startSeconds: 30, endSeconds: 30, text: "We'll be right back."),
            TranscriptSegment(startSeconds: 30, endSeconds: 30.12, text: "you"),
            TranscriptSegment(startSeconds: 0, endSeconds: 5, text: "実際の発話はちゃんと残る"),
        ]
        let r = AmbientTranscriber.classify(segs)
        XCTAssertEqual(r.kept.map(\.text), ["実際の発話はちゃんと残る"])
        XCTAssertTrue(r.skipped.allSatisfy { $0.reason == "zero_duration" })
    }

    func testClassifyDropsNonSpeechMarkers() {
        let segs = [
            TranscriptSegment(startSeconds: 0, endSeconds: 9, text: "*coughs*"),
            TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "*Louds of the street*"),
            TranscriptSegment(startSeconds: 0, endSeconds: 3, text: "(música)"),
        ]
        let r = AmbientTranscriber.classify(segs)
        XCTAssertTrue(r.kept.isEmpty)
        XCTAssertTrue(r.skipped.allSatisfy { $0.reason == "non_speech_marker" })
    }

    func testClassifyDropsCanonicalBoilerplate() {
        let segs = [
            TranscriptSegment(startSeconds: 0, endSeconds: 30, text: "ご視聴ありがとうございました"),
            TranscriptSegment(startSeconds: 0, endSeconds: 30, text: "- Thank you."),
            TranscriptSegment(startSeconds: 0, endSeconds: 4, text: "Thank you for the report, it helped."),
        ]
        let r = AmbientTranscriber.classify(segs)
        // Boilerplate only when it is the whole segment — real sentences stay.
        XCTAssertEqual(r.kept.map(\.text), ["Thank you for the report, it helped."])
        XCTAssertTrue(r.skipped.allSatisfy { $0.reason == "hallucination_boilerplate" })
    }

    func testRepetitionDetectorCatchesLoopsAndJpPeriodic() {
        XCTAssertTrue(AmbientTranscriber.isInternalRepetition("餃子餃子餃子"))
        XCTAssertTrue(AmbientTranscriber.isInternalRepetition(
            "The first time I was in the first place, I was in the first place. I was in the first place."))
        XCTAssertFalse(AmbientTranscriber.isInternalRepetition("明日の打ち合わせの資料をまとめておきます"))
        XCTAssertFalse(AmbientTranscriber.isInternalRepetition(
            "We should review the release plan and the test results before Thursday."))
    }

    // MARK: - Log display grouping + segment timestamp compatibility

    func testTranscriptSegmentDecodesLegacyLinesWithoutCapturedAt() throws {
        let legacy = #"{"startSeconds":0,"endSeconds":4,"text":"right"}"#
        let seg = try JSONDecoder().decode(TranscriptSegment.self, from: Data(legacy.utf8))
        XCTAssertNil(seg.capturedAt)
        XCTAssertEqual(seg.text, "right")
    }

    func testLogGroupingMergesCloseSegmentsAndSplitsOnGap() {
        var s1 = TranscriptSegment(startSeconds: 0, endSeconds: 3, text: "こんにちは")
        s1.capturedAt = 1_700_000_000
        var s2 = TranscriptSegment(startSeconds: 3, endSeconds: 6, text: "今日の予定だけど")
        s2.capturedAt = 1_700_000_010
        var s3 = TranscriptSegment(startSeconds: 0, endSeconds: 4, text: "全然別の話")
        s3.capturedAt = 1_700_000_500  // 490s later → new block

        let blocks = AmbientLogGrouping.blocks(
            from: [s1, s2, s3], timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].text, "こんにちは 今日の予定だけど")
        XCTAssertNotNil(blocks[0].timeLabel)
        XCTAssertEqual(blocks[1].text, "全然別の話")
    }

    func testLogGroupingHandlesLegacySegmentsWithoutTimestamps() {
        let s1 = TranscriptSegment(startSeconds: 0, endSeconds: 3, text: "a")
        let s2 = TranscriptSegment(startSeconds: 3, endSeconds: 6, text: "b")
        let blocks = AmbientLogGrouping.blocks(from: [s1, s2])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "a b")
        XCTAssertNil(blocks[0].timeLabel)
    }

    // MARK: - L2 salient extraction

    private static let fixedNow: Date = {
        // 2026-06-10 12:00 JST (Wednesday)
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 10; c.hour = 12
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    private static var jstCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return cal
    }

    func testSalientExtractsTomorrowMeetingAsAppointment() throws {
        let d = try XCTUnwrap(AmbientSalientExtractor.extractOne(
            from: "明日の14時にリリース計画の打ち合わせをしましょう",
            now: Self.fixedNow, calendar: Self.jstCalendar))
        XCTAssertEqual(d.eventType, "appointment")
        XCTAssertEqual(d.normalizedDateBucket, "2026-06-11")
        XCTAssertFalse(d.normalizedSubject.isEmpty)
        XCTAssertEqual(d.dedupKey.count, 16)
    }

    func testSalientExtractsEnglishTodo() throws {
        let d = try XCTUnwrap(AmbientSalientExtractor.extractOne(
            from: "Don't forget the deployment checklist for the gateway",
            now: Self.fixedNow, calendar: Self.jstCalendar))
        XCTAssertEqual(d.eventType, "todo")
        XCTAssertNil(d.normalizedDateBucket)
    }

    func testSalientIgnoresPlainConversation() {
        XCTAssertNil(AmbientSalientExtractor.extractOne(
            from: "今日はいい天気だね", now: Self.fixedNow, calendar: Self.jstCalendar))
        XCTAssertNil(AmbientSalientExtractor.extractOne(
            from: "The weather is nice.", now: Self.fixedNow, calendar: Self.jstCalendar))
    }

    func testSalientDedupKeyMatchesContractFormula() {
        // sha1("appointment|release meeting|2026-06-11").hex[:16] — stable.
        let a = AmbientSalientExtractor.dedupKey(
            eventType: "appointment", subject: "release meeting", bucket: "2026-06-11")
        let b = AmbientSalientExtractor.dedupKey(
            eventType: "appointment", subject: "release meeting", bucket: "2026-06-11")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 16)
        // Different bucket → different key (time-bucketed identity).
        let c = AmbientSalientExtractor.dedupKey(
            eventType: "appointment", subject: "release meeting", bucket: "2026-06-12")
        XCTAssertNotEqual(a, c)
    }

    func testSalientRedactsHonorificAdjacentNamesJa() throws {
        let d = try XCTUnwrap(AmbientSalientExtractor.extractOne(
            from: "明日、田中さんとリリース計画の打ち合わせをします",
            now: Self.fixedNow, calendar: Self.jstCalendar))
        XCTAssertFalse(d.normalizedSubject.contains("田中"), "honorific-adjacent name must be redacted")
        XCTAssertFalse(d.summary.contains("田中"))
    }

    func testSalientExtractsBelonging() throws {
        let d = try XCTUnwrap(AmbientSalientExtractor.extractOne(
            from: "傘を持っていくのを忘れないでね",
            now: Self.fixedNow, calendar: Self.jstCalendar))
        XCTAssertEqual(d.eventType, "belonging")
    }

    func testSalientPrecisionGuardsRejectNoise() {
        let mustNotExtract = [
            "昨日の打ち合わせは長かったね",                       // retrospective
            "先週の会議で決まった件だけど",                       // retrospective
            "ご視聴ありがとうございました",                       // media boilerplate
            "Thanks for watching, don't forget to subscribe",   // media (beats todo marker)
            "田中さんは明日打ち合わせがあるらしいよ",               // hearsay third-party plan
            "今日はいい天気だね",                                // plain chatter
        ]
        for text in mustNotExtract {
            XCTAssertNil(AmbientSalientExtractor.extractOne(
                from: text, now: Self.fixedNow, calendar: Self.jstCalendar),
                "must not extract from: \(text)")
        }
    }

    func testSalientRedactsTaggedNamesEn() throws {
        // EN path: NLTagger tags "Alice" as personalName (not noun) → excluded.
        let d = try XCTUnwrap(AmbientSalientExtractor.extractOne(
            from: "I'll send the report to Alice before the deadline",
            now: Self.fixedNow, calendar: Self.jstCalendar))
        XCTAssertFalse(d.normalizedSubject.contains("alice"), "EN tagged name must be redacted")
        XCTAssertFalse(d.summary.lowercased().contains("alice"))
    }

    func testSalientRedactsLatinNameInJapaneseText() throws {
        // JP fallback path: no name tags available, so title-case latin tokens
        // are treated as likely proper names and redacted.
        let d = try XCTUnwrap(AmbientSalientExtractor.extractOne(
            from: "明日Aliceとリリース計画の打ち合わせの予定",
            now: Self.fixedNow, calendar: Self.jstCalendar))
        XCTAssertFalse(d.normalizedSubject.contains("alice"), "latin name in JP text must be redacted")
        XCTAssertFalse(d.summary.lowercased().contains("alice"))
    }

    func testSalientSameEventTwiceCollapsesInWindow() {
        let drafts = AmbientSalientExtractor.extract(
            from: ["明日リリースの打ち合わせをしましょう",
                   "明日の打ち合わせ、リリースの件ね"],
            now: Self.fixedNow, calendar: Self.jstCalendar)
        // Same type+subject-nouns+bucket should dedupe to one draft when the
        // noun sets coincide; at minimum it must never duplicate dedupKeys.
        let keys = drafts.map { $0.dedupKey }
        XCTAssertEqual(keys.count, Set(keys).count)
    }
}
