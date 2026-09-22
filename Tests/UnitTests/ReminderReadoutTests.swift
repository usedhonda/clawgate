import XCTest
@testable import ClawGate

/// Deciding what to do with a reminder, remembering which ones were read, and
/// levelling the synthesized clip. Pure logic only — nothing here synthesizes,
/// plays audio, or posts a receipt.
final class ReminderReadoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func payload(kind: String? = ReminderPayload.calendarImminent,
                         speech: String? = "18時30分から、打ち合わせ。あと10分だよ。オンライン。",
                         speakOn: String? = "mac",
                         reminderId: String? = "calendar_imminent:evt-1:2026-09-22T13:30:00Z",
                         expiresAt: String? = "2026-09-22T13:30:00Z") -> ReminderPayload {
        ReminderPayload(kind: kind, speech: speech, speakOn: speakOn,
                        reminderId: reminderId, startUtc: expiresAt, expiresAt: expiresAt)
    }

    private func decide(_ p: ReminderPayload, at date: Date? = nil, seen: Set<String> = []) -> ReminderDecision {
        ReminderReadoutDecider.decide(p, now: date ?? now, seen: seen)
    }

    // MARK: - Not ours

    func testAnotherKindIsNotSpokenAndNotReported() {
        XCTAssertEqual(decide(payload(kind: "calendar_soon")), .ignore)
        XCTAssertEqual(decide(payload(kind: nil)), .ignore)
    }

    func testWithoutSpeakOnMacTheMacStaysQuiet() {
        // The Gateway decides which device speaks; no marker means not this one.
        XCTAssertEqual(decide(payload(speakOn: nil)), .ignore)
        XCTAssertEqual(decide(payload(speakOn: "phone")), .ignore)
    }

    func testWithoutAnIdThereIsNothingToReportAgainst() {
        XCTAssertEqual(decide(payload(reminderId: nil)), .ignore)
        XCTAssertEqual(decide(payload(reminderId: "   ")), .ignore)
    }

    // MARK: - Ours, but not spoken

    func testAnEmptyScriptIsNeverReplacedByTheDisplayText() {
        guard case .skip(_, let outcome) = decide(payload(speech: "")) else {
            return XCTFail("expected a skip")
        }
        XCTAssertEqual(outcome, "skipped:speech_empty")
        guard case .skip(_, let blank) = decide(payload(speech: "  \n ")) else {
            return XCTFail("expected a skip")
        }
        XCTAssertEqual(blank, "skipped:speech_empty")
    }

    func testAReminderForAnEventThatHasStartedIsNotRead() {
        // Waking from sleep, or a resend, delivers these late.
        let late = Date(timeIntervalSince1970: 1_790_000_000 + 10 * 86_400)
        guard case .skip(_, let outcome) = decide(payload(), at: late) else {
            return XCTFail("expected a skip")
        }
        XCTAssertEqual(outcome, "skipped:expired")
    }

    func testTheSameReminderIsNeverReadTwice() {
        let p = payload()
        guard case .skip(_, let outcome) = decide(p, seen: [p.reminderId!]) else {
            return XCTFail("expected a skip")
        }
        XCTAssertEqual(outcome, "skipped:duplicate")
    }

    func testAnUnparsableExpiryDoesNotSilenceTheReminder() {
        // Better to read one late than to swallow every reminder on a format change.
        guard case .speak = decide(payload(expiresAt: "not-a-date")) else {
            return XCTFail("expected to speak")
        }
    }

    // MARK: - Ours and spoken

    func testAFreshReminderIsSpoken() {
        guard case .speak(let id, let speech) = decide(payload()) else {
            return XCTFail("expected to speak")
        }
        XCTAssertEqual(id, "calendar_imminent:evt-1:2026-09-22T13:30:00Z")
        XCTAssertTrue(speech.hasPrefix("18時30分から"))
    }

    func testExpiryAcceptsFractionalSeconds() {
        XCTAssertNotNil(ReminderReadoutDecider.parseISO8601("2026-09-22T13:30:00.250Z"))
        XCTAssertNotNil(ReminderReadoutDecider.parseISO8601("2026-09-22T13:30:00Z"))
        XCTAssertNil(ReminderReadoutDecider.parseISO8601("2026-09-22 13:30"))
    }

    // MARK: - Remembering what was read

    func testIdsAreForgottenAfterTheRetentionWindow() throws {
        let suite = "clawgate.tests.reminder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = ReminderMemory(defaults: defaults)

        memory.remember("a", now: now)
        XCTAssertTrue(memory.ids(now: now).contains("a"))
        XCTAssertTrue(memory.ids(now: now.addingTimeInterval(ReminderMemory.retention - 60)).contains("a"))
        XCTAssertFalse(memory.ids(now: now.addingTimeInterval(ReminderMemory.retention + 60)).contains("a"))
    }

    // MARK: - Levelling the clip

    /// A 16-bit mono WAV whose loudest sample is `peak`.
    private func wav(peak: Int16, samples count: Int = 8) -> Data {
        var pcm = [Int16](repeating: 0, count: count)
        pcm[count / 2] = peak
        var out = Data()
        let dataBytes = pcm.withUnsafeBytes { Data($0) }
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(contentsOf: withUnsafeBytes(of: UInt32(36 + dataBytes.count).littleEndian) { Array($0) })
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        out.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        out.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })    // PCM
        out.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })    // mono
        out.append(contentsOf: withUnsafeBytes(of: UInt32(24_000).littleEndian) { Array($0) })
        out.append(contentsOf: withUnsafeBytes(of: UInt32(48_000).littleEndian) { Array($0) })
        out.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        out.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        out.append(contentsOf: Array("data".utf8))
        out.append(contentsOf: withUnsafeBytes(of: UInt32(dataBytes.count).littleEndian) { Array($0) })
        out.append(dataBytes)
        return out
    }

    private func peak(of wav: Data) throws -> Int16 {
        let range = try XCTUnwrap(WavPeakNormalizer.dataChunkRange(wav))
        var pcm = [Int16](repeating: 0, count: range.count / 2)
        _ = pcm.withUnsafeMutableBytes { wav.copyBytes(to: $0, from: range) }
        return pcm.map { Int16(abs(Int32($0))) }.max() ?? 0
    }

    func testAQuietClipIsBroughtUpToJustUnderFullScale() throws {
        let quiet = wav(peak: 3_000)
        let levelled = try XCTUnwrap(WavPeakNormalizer.normalized(quiet, toDBFS: -1))
        let expected = Int16(pow(10.0, -1.0 / 20.0) * Double(Int16.max))
        XCTAssertEqual(try peak(of: levelled), expected, accuracy: 2)
        XCTAssertEqual(levelled.count, quiet.count)
    }

    func testAFullScaleClipIsBroughtDownToTheSameTarget() throws {
        // Normalization is two-directional: the voice settings use a volume
        // scale above 1, so most clips arrive at full scale and must come down.
        let loud = try XCTUnwrap(WavPeakNormalizer.normalized(wav(peak: Int16.max), toDBFS: -1))
        let expected = Int16(pow(10.0, -1.0 / 20.0) * Double(Int16.max))
        XCTAssertEqual(try peak(of: loud), expected, accuracy: 2)
    }

    func testSilenceAndNonWavDataAreRejectedRatherThanScaled() {
        XCTAssertNil(WavPeakNormalizer.normalized(wav(peak: 0), toDBFS: -1))
        XCTAssertNil(WavPeakNormalizer.normalized(Data("not a wav at all".utf8), toDBFS: -1))
        XCTAssertNil(WavPeakNormalizer.dataChunkRange(Data()))
    }

    // MARK: - The Gateway's own payload

    /// The exact example oc-general sent from their implementation
    /// (2026-09-22). The six fields sit at the payload's top level, beside
    /// runId/state/sessionKey, and only the terminal state carries them.
    private static let gatewayExample = """
    {"sessionKey":"agent:main:main","sessionId":"agent:main:main","state":"final",
     "runId":"11111111-2222-3333-4444-555555555555",
     "text":"18時30分から、打ち合わせ。あと10分だよ。オンライン。",
     "kind":"calendar_imminent",
     "speech":"18時30分から、打ち合わせ。あと10分だよ。オンライン。",
     "speakOn":"mac",
     "reminderId":"calendar_imminent:evt-abc123:2026-09-22T09:30:00.000Z",
     "startUtc":"2026-09-22T09:30:00.000Z",
     "expiresAt":"2026-09-22T09:30:00.000Z"}
    """

    private func decodePayload(_ json: String) throws -> IncomingPayload {
        try JSONDecoder().decode(IncomingPayload.self, from: Data(json.utf8))
    }

    func testTheGatewaysPayloadBecomesAReminderEvent() throws {
        let payload = try decodePayload(Self.gatewayExample)
        let events = OpenClawWSClient.routeIncomingEvent(name: "chat", payload: payload)
        guard events.count == 1, case .reminder(let reminder) = events[0] else {
            return XCTFail("expected exactly one reminder event, got \(events)")
        }
        XCTAssertEqual(reminder.kind, ReminderPayload.calendarImminent)
        XCTAssertEqual(reminder.speakOn, "mac")
        XCTAssertEqual(reminder.reminderId, "calendar_imminent:evt-abc123:2026-09-22T09:30:00.000Z")
        XCTAssertEqual(reminder.expiresAt, "2026-09-22T09:30:00.000Z")
        // Before the event starts it is read; the same payload after is not.
        let before = Date(timeIntervalSince1970: 1_790_000_000)   // well before
        guard case .speak = ReminderReadoutDecider.decide(reminder, now: before, seen: []) else {
            return XCTFail("expected to speak before the event starts")
        }
    }

    func testAReminderIsNotTakenOffANonTerminalState() throws {
        // The Gateway only fills these on the final build; taking them off a
        // delta too would be a second readout of the same reminder.
        let delta = Self.gatewayExample.replacingOccurrences(of: "\"state\":\"final\"", with: "\"state\":\"delta\"")
        let events = OpenClawWSClient.routeIncomingEvent(name: "chat", payload: try decodePayload(delta))
        XCTAssertFalse(events.contains { if case .reminder = $0 { return true } else { return false } })
    }

    func testAnOrdinaryChatReplyIsStillAMessage() throws {
        let reply = """
        {"sessionKey":"agent:main:main","state":"final","runId":"abc",
         "message":{"role":"assistant","content":[{"type":"text","text":"はい"}]}}
        """
        let events = OpenClawWSClient.routeIncomingEvent(name: "chat", payload: try decodePayload(reply))
        guard events.count == 1, case .message(let msg) = events[0] else {
            return XCTFail("the reminder path must not swallow ordinary replies: \(events)")
        }
        XCTAssertEqual(msg.text, "はい")
    }

    // MARK: - Real VOICEVOX synthesis (opt-in)

    /// Needs the local VOICEVOX engine. Run with:
    ///   VOICEVOX_TEST=1 swift test --filter ReminderReadoutTests
    func testVoicevoxProducesALevelledWav() throws {
        guard ProcessInfo.processInfo.environment["VOICEVOX_TEST"] == "1" else {
            throw XCTSkip("VOICEVOX_TEST not set")
        }
        let wav = try VoicevoxSynthesizer().synthesize("18時30分から、打ち合わせ。あと10分だよ。オンライン。")
        XCTAssertNotNil(WavPeakNormalizer.dataChunkRange(wav), "not a WAV we can read")
        let expected = Int16(pow(10.0, -1.0 / 20.0) * Double(Int16.max))
        XCTAssertEqual(try peak(of: wav), expected, accuracy: 4, "clip is not levelled to -1 dBFS")
    }

    /// Reads this Mac's real output state. Opt-in because the answer depends on
    /// how the machine is set up right now; it proves the CoreAudio reads work
    /// and never invent an outcome outside the agreed vocabulary.
    func testOutputStateReadsAsAKnownOutcome() throws {
        guard ProcessInfo.processInfo.environment["VOICEVOX_TEST"] == "1" else {
            throw XCTSkip("VOICEVOX_TEST not set")
        }
        let outcome = ReminderAudioOutput.blockingOutcome()
        print("output state: \(outcome ?? "playable")")
        if let outcome {
            XCTAssertTrue(["skipped:no_output_device", "skipped:volume_zero"].contains(outcome), outcome)
        }
    }

    // MARK: - Observability: recent decisions

    private func service(suite: String) -> ReminderReadoutService {
        let defaults = UserDefaults(suiteName: suite)!
        return ReminderReadoutService(memory: ReminderMemory(defaults: defaults), receipts: { nil })
    }

    func testANonReminderPayloadIsTracedAsIgnored() throws {
        let suite = "clawgate.tests.reminder.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let svc = service(suite: suite)

        let handled = svc.handle(payload(kind: "calendar_soon"), now: now)

        XCTAssertFalse(handled)
        let traces = svc.recentTraces()
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual(traces[0].decision, "ignore")
        XCTAssertNil(traces[0].outcome)
    }

    func testAnExpiredReminderIsTracedAsSkipped() throws {
        let suite = "clawgate.tests.reminder.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let svc = service(suite: suite)
        let late = Date(timeIntervalSince1970: 1_790_000_000 + 10 * 86_400)

        let handled = svc.handle(payload(), now: late)

        XCTAssertTrue(handled)
        let traces = svc.recentTraces()
        XCTAssertEqual(traces.count, 1)
        XCTAssertEqual(traces[0].decision, "skipped:expired")
        XCTAssertEqual(traces[0].outcome, "skipped:expired")
    }

    func testTracesAreKeptToFiftyNewestFirst() throws {
        let suite = "clawgate.tests.reminder.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let svc = service(suite: suite)

        for i in 0..<60 {
            svc.handle(payload(kind: "calendar_soon", reminderId: "unused-\(i)"), now: now)
        }

        let traces = svc.recentTraces()
        XCTAssertEqual(traces.count, 50)
        // Newest first: the very last handled payload leads.
        XCTAssertEqual(traces.first?.reminderId, "unused-59")
    }

    func testTheDataChunkIsFoundPastAnExtraChunk() throws {
        // A LIST chunk before `data` is legal; assuming a 44-byte header is not.
        var padded = wav(peak: 1_000)
        let insertAt = 36   // right after fmt , before "data"
        var extra = Data(Array("LIST".utf8))
        extra.append(contentsOf: withUnsafeBytes(of: UInt32(4).littleEndian) { Array($0) })
        extra.append(contentsOf: Array("INFO".utf8))
        padded.insert(contentsOf: extra, at: insertAt)
        let range = try XCTUnwrap(WavPeakNormalizer.dataChunkRange(padded))
        XCTAssertEqual(range.count, 16)
    }
}
