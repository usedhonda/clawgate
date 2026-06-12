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

    func testIngestSummaryCarriesTheWindowTranscript() {
        let segments = [
            "We should ship the release on Thursday after the review meeting.",
            "The release branch still has two failing integration tests today.",
            "Let me check the release pipeline before the meeting starts.",
        ]
        let params = AmbientIngestProducer.buildParams(
            lines: segments.map { .init(text: $0, speaker: nil, capturedAt: nil) },
            windowStart: Date(timeIntervalSince1970: 1_700_000_000),
            windowEnd: Date(timeIntervalSince1970: 1_700_000_060),
            sessionID: "ctx-test",
            sourceSeq: 1,
            now: Date(timeIntervalSince1970: 1_700_000_061)
        )
        // 御大 ruling 2026-06-11: the assistant gets the actual text, like any
        // minutes app — no self-imposed redaction of the owner's own audio.
        for s in segments {
            XCTAssertTrue(params.state.summary.contains(s), "summary must carry the transcript: \(s)")
        }
    }

    func testWindowTranscriptCapsToRecentTail() {
        let long = Array(repeating: "0123456789", count: 300)  // 3000+ chars
        let capped = AmbientIngestProducer.windowTranscript(long, maxChars: 100)
        XCTAssertTrue(capped.count <= 101)  // ellipsis + tail
        XCTAssertTrue(capped.hasPrefix("…"))
    }

    func testIngestParamsSchemaShape() throws {
        let params = AmbientIngestProducer.buildParams(
            lines: [
                .init(text: "release planning discussion", speaker: nil, capturedAt: nil),
                .init(text: "release timing details", speaker: nil, capturedAt: nil),
            ],
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
        XCTAssertNil(blocks[0].speaker)
    }

    // MARK: - Speaker diarization (helper merge + grouping + dialogue summary)

    func testTranscriptSegmentDecodesLegacyLinesWithoutSpeaker() throws {
        let legacy = #"{"startSeconds":0,"endSeconds":4,"text":"right","capturedAt":1700000000}"#
        let seg = try JSONDecoder().decode(TranscriptSegment.self, from: Data(legacy.utf8))
        XCTAssertNil(seg.speaker)
    }

    func testDiarizerLabelAssignsSpeakerByMaxOverlap() {
        let segs = [
            TranscriptSegment(startSeconds: 0, endSeconds: 4, text: "おはよう"),
            TranscriptSegment(startSeconds: 4, endSeconds: 8, text: "はい、おはようございます"),
            TranscriptSegment(startSeconds: 20, endSeconds: 22, text: "枠外の発話"),
        ]
        let turns = [
            SpeakerTurn(start: 0, end: 4.5, speaker: "self", score: 0.8),
            SpeakerTurn(start: 4.5, end: 9, speaker: "other", score: 0.3),
        ]
        let labeled = AmbientDiarizer.label(segments: segs, with: turns)
        XCTAssertEqual(labeled[0].speaker, "self")
        XCTAssertEqual(labeled[1].speaker, "other")  // 3.5s other vs 0.5s self
        XCTAssertNil(labeled[2].speaker, "no overlapping turn → unlabeled")
    }

    func testLogGroupingSplitsOnSpeakerChange() {
        var s1 = TranscriptSegment(startSeconds: 0, endSeconds: 3, text: "明日の予定だけど")
        s1.capturedAt = 1_700_000_000; s1.speaker = "self"
        var s2 = TranscriptSegment(startSeconds: 3, endSeconds: 6, text: "14時でどうですか")
        s2.capturedAt = 1_700_000_005; s2.speaker = "other"
        var s3 = TranscriptSegment(startSeconds: 6, endSeconds: 9, text: "それでいこう")
        s3.capturedAt = 1_700_000_010; s3.speaker = "self"

        let blocks = AmbientLogGrouping.blocks(
            from: [s1, s2, s3], timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.map(\.speaker), ["self", "other", "self"])
        XCTAssertEqual(blocks[1].text, "14時でどうですか")
    }

    func testDialogueSummaryFormatsSpeakerTurns() {
        let jst = TimeZone(identifier: "Asia/Tokyo")!
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let lines: [AmbientIngestProducer.Line] = [
            .init(text: "明日の打ち合わせだけど", speaker: "self", capturedAt: t0),
            .init(text: "14時からにしよう", speaker: "self", capturedAt: t0.addingTimeInterval(4)),
            .init(text: "はい、14時で大丈夫です", speaker: "other", capturedAt: t0.addingTimeInterval(8)),
        ]
        let summary = AmbientIngestProducer.dialogueSummary(lines, timeZone: jst)
        let rendered = summary.components(separatedBy: "\n")
        XCTAssertEqual(rendered.count, 2, "consecutive same-speaker lines merge into one utterance")
        XCTAssertTrue(rendered[0].contains("ご主人様: 明日の打ち合わせだけど 14時からにしよう"))
        XCTAssertTrue(rendered[0].hasPrefix("["), "utterance carries a [HH:mm] head")
        XCTAssertTrue(rendered[1].contains("相手: はい、14時で大丈夫です"))
    }

    func testDialogueSummaryDegradesToPlainTranscriptWithoutSpeakers() {
        let lines: [AmbientIngestProducer.Line] = [
            .init(text: "plain one", speaker: nil, capturedAt: nil),
            .init(text: "plain two", speaker: nil, capturedAt: nil),
        ]
        XCTAssertEqual(AmbientIngestProducer.dialogueSummary(lines), "plain one plain two")
    }

    func testDialogueSummaryCapsToRecentTail() {
        let lines = (0..<300).map {
            AmbientIngestProducer.Line(text: "0123456789", speaker: $0 % 2 == 0 ? "self" : "other", capturedAt: nil)
        }
        let capped = AmbientIngestProducer.dialogueSummary(lines, maxChars: 100)
        XCTAssertTrue(capped.count <= 101)
        XCTAssertTrue(capped.hasPrefix("…"))
    }

    func testAttributedTranscriptJoinsAllBlocksIntoOneSelectableText() {
        let blocks = [
            AmbientLogGrouping.Block(timeLabel: "11:02", speaker: "self", text: "明日の予定だけど"),
            AmbientLogGrouping.Block(timeLabel: "11:02", speaker: "other", text: "14時でどうですか"),
            AmbientLogGrouping.Block(timeLabel: nil, speaker: nil, text: "旧データはヘッダなし"),
        ]
        let plain = String(AmbientLogPetView.attributedTranscript(blocks).characters)
        XCTAssertTrue(plain.contains("11:02 ご主人様\n明日の予定だけど"))
        XCTAssertTrue(plain.contains("11:02 相手\n14時でどうですか"))
        XCTAssertTrue(plain.hasSuffix("旧データはヘッダなし"))
    }

    func testPresentSpeakersReflectsDiarizedParties() {
        let both: [AmbientIngestProducer.Line] = [
            .init(text: "a", speaker: "self", capturedAt: nil),
            .init(text: "b", speaker: "other", capturedAt: nil),
        ]
        XCTAssertEqual(AmbientIngestProducer.presentSpeakers(in: both), ["ご主人様", "相手"])
        let none: [AmbientIngestProducer.Line] = [.init(text: "a", speaker: nil, capturedAt: nil)]
        XCTAssertTrue(AmbientIngestProducer.presentSpeakers(in: none).isEmpty)
    }

    func testDiarizerUnavailableWhenBinaryOrVoiceprintMissing() {
        let d = AmbientDiarizer(
            binary: URL(fileURLWithPath: "/nonexistent/clawgate-diarizer"),
            voiceprint: URL(fileURLWithPath: "/nonexistent/self.json"))
        XCTAssertFalse(d.isAvailable)
        XCTAssertNil(d.diarize(chunk: URL(fileURLWithPath: "/tmp/whatever.wav")),
                     "missing helper must fail soft (nil), never throw or block")
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
