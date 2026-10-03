import XCTest
@testable import ClawGate

/// 2026-09-29: every multi-part meeting failed. The Gateway ended the second
/// part's run at once ("Current-turn transcript admission is no longer a
/// visible message") and said so with a `chat` event in state `error`, which
/// the client dropped. It then waited 600s, failed the whole meeting, and a
/// retry by hand threw away the part already written.
final class MeetingMinutesRetryTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!
    private var model: PetModel!
    private var originalGap: TimeInterval = 0

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-retry-\(UUID().uuidString)")
        store = MeetingStore(root: root)
        originalGap = PetModel.minutesPartGapSeconds
        model = PetModel()
        model.setMeetingStoreForTesting(store)
        model.setSessionKeyForTesting("agent:main:main")
        model.setConnectionStateForTesting(.connected)
        // Long enough to need more than one part.
        let text = String(repeating: "議題について詳しく話し合いました。", count: 60)
        model.meetingTranscriptProvider = { _ in
            (0..<30).map { i in
                var s = TranscriptSegment(startSeconds: Double(i), endSeconds: Double(i) + 1, text: text)
                s.capturedAt = 1_790_000_000 + Double(i * 10)
                return s
            }
        }
        model.suppressLogSendForTesting = true
    }

    override func tearDown() {
        PetModel.minutesPartGapSeconds = originalGap
        model.cleanup()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func meeting() -> MeetingRecord {
        let record = MeetingRecord(id: "mtg-retry", source: "meet", startedAt: 1_790_000_000,
                                   endedAt: 1_790_003_600, timeZone: "UTC", title: "retry",
                                   conferenceCode: nil, participants: [], minutesState: "none", minutesError: nil)
        store.save(record)
        return record
    }

    private func drainMain() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    func testGatewayRunErrorIsRoutedAsRunFailure() throws {
        let payload = try JSONDecoder().decode(IncomingPayload.self, from: Data("""
        {"runId":"run-2","sessionKey":"agent:main:main","state":"error","errorMessage":"fence"}
        """.utf8))
        let events = OpenClawWSClient.routeIncomingEvent(name: "chat", payload: payload)
        guard case .runFailed(let owner, let reason)? = events.first else {
            return XCTFail("a chat error must reach the client as a run failure")
        }
        XCTAssertEqual(owner.runId, "run-2")
        XCTAssertEqual(reason, "fence")
    }

    func testFailedPartRetriesLaterAndKeepsWrittenParts() throws {
        let record = meeting()
        model.requestMinutes(for: record)
        XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, record.id)
        var job = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        XCTAssertGreaterThan(job.envelopes.count, 1)
        // The first part was written; the second is in flight.
        job.completed = [nil]
        try job.save(store: store, id: record.id)
        model.acknowledgeSharedSummonForTesting(runId: "run-2")

        model.handleEvent(.runFailed(owner: OpenClawEventOwnerIdentity(messageId: "run-2", runId: "run-2"),
                                     reason: "fence"))
        drainMain()

        XCTAssertNil(model.pendingMinutesMeetingIDForTesting, "the backoff must hold the retry, not resend at once")
        let after = try XCTUnwrap(store.load(id: record.id))
        XCTAssertEqual(after.minutesState, "pending")
        XCTAssertTrue(after.minutesError?.contains("再試行") == true)
        XCTAssertEqual(MeetingMinutesJob.load(store: store, id: record.id)?.completed.count, 1)

        // Resuming by hand continues from the same part.
        model.releaseCurrentSharedSummonForTesting()
        model.resumeMinutes(for: after)
        XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, record.id)
        XCTAssertEqual(MeetingMinutesJob.load(store: store, id: record.id)?.completed.count, 1)
    }

    func testSourceRefreshDoesNotReplaceFrozenPendingInput() throws {
        let record = meeting()
        model.requestMinutes(for: record)
        var frozen = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        frozen.completed = [nil]
        try frozen.save(store: store, id: record.id)
        model.releaseCurrentSharedSummonForTesting()
        model.meetingTranscriptProvider = { _ in [TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Newly fetched source")] }
        let pending = try XCTUnwrap(store.load(id: record.id))
        model.requestMinutes(for: pending, markUserRequested: false)
        let after = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        XCTAssertEqual(after.fingerprint, frozen.fingerprint)
        XCTAssertEqual(after.completed.count, 1)
        XCTAssertEqual(after.envelopes.flatMap(\.segments), frozen.envelopes.flatMap(\.segments))
    }

    func testAFailureFromAnotherRunIsIgnored() throws {
        let record = meeting()
        model.requestMinutes(for: record)
        model.acknowledgeSharedSummonForTesting(runId: "run-mine")
        model.handleEvent(.runFailed(owner: OpenClawEventOwnerIdentity(messageId: "x", runId: "run-other",
                                                                       sessionKey: "agent:main:proactive"),
                                     reason: "fence"))
        drainMain()
        XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, record.id, "another session's failure is not ours")

        // Once our run has streamed, a same-session failure of another run
        // is not ours either.
        model.handleEvent(.delta(messageId: OpenClawEventOwnerIdentity(messageId: "run-mine", runId: "run-mine"), text: "{"))
        model.handleEvent(.runFailed(owner: OpenClawEventOwnerIdentity(messageId: "x", runId: "run-other",
                                                                       sessionKey: "agent:main:main"),
                                     reason: "fence"))
        drainMain()
        XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, record.id)
    }

    /// The Gateway reports the failed turn under its own run id, not the ACK's.
    func testASameSessionFailureBeforeAnyOutputIsOurs() throws {
        let record = meeting()
        model.requestMinutes(for: record)
        model.acknowledgeSharedSummonForTesting(runId: "run-mine")
        model.handleEvent(.runFailed(owner: OpenClawEventOwnerIdentity(messageId: "x", runId: "run-gateway",
                                                                       sessionKey: "agent:main:main"),
                                     reason: "fence"))
        drainMain()
        XCTAssertNil(model.pendingMinutesMeetingIDForTesting)
        XCTAssertTrue(store.load(id: record.id)?.minutesError?.contains("再試行") == true)
    }

    /// 2026-09-29: the calendar association arrived after the first request
    /// and the first meeting's written part was thrown away.
    func testCalendarMetadataArrivingLaterKeepsWrittenParts() throws {
        var record = meeting()
        let segments = model.meetingTranscriptProvider?(record) ?? []
        let before = MeetingMinutesEnvelope.build(record: record, segments: segments)
        var job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(before),
                                    envelopes: MeetingMinutes.chunked(before), completed: [nil])
        XCTAssertGreaterThan(job.envelopes.count, 1)

        record.calendarEventID = "event-1"
        record.calendarEventStart = record.startedAt
        record.calendarEventEnd = record.startedAt + 3600
        let after = MeetingMinutesEnvelope.build(record: record, segments: segments)
        XCTAssertEqual(MeetingMinutesJob.fingerprint(after), job.fingerprint)

        job = job.refreshingMetadata(from: after)
        XCTAssertEqual(job.completed.count, 1)
        XCTAssertEqual(job.next?.calendarEventID, "event-1")
    }

    func testActivityDistinguishesSendingFromQueuedMeeting() {
        let first = meeting()
        model.requestMinutes(for: first)
        let active = store.load(id: first.id)!
        XCTAssertEqual(model.minutesActivity(for: active)?.label, "生成依頼を送信中")
        XCTAssertNotNil(model.minutesActivity(for: active)?.elapsedSeconds)
        var waiting = first
        waiting.id = "mtg-waiting"
        store.save(waiting)
        model.requestMinutes(for: waiting)
        XCTAssertEqual(model.minutesActivity(for: store.load(id: waiting.id)!)?.label, "別の議事録処理の完了待ち")
        XCTAssertNil(model.minutesActivity(for: store.load(id: waiting.id)!)?.elapsedSeconds)
    }

    func testActivityElapsedResetsWhenGenerationStarts() throws {
        let record = meeting()
        model.requestMinutes(for: record)
        let active = try XCTUnwrap(store.load(id: record.id))
        let dispatchStarted = try XCTUnwrap(model.minutesActivityPhaseStartedAtForTesting.dispatch)
        let sending = try XCTUnwrap(model.minutesActivity(for: active,
                                                          now: dispatchStarted.addingTimeInterval(8)))
        XCTAssertEqual(sending.label, "生成依頼を送信中")
        XCTAssertEqual(sending.elapsedSeconds, 8)

        let staleToken = UUID()
        model.acknowledgeSharedSummonForTesting(runId: "run-stale", token: staleToken)
        XCTAssertNil(model.minutesActivityPhaseStartedAtForTesting.generation,
                     "an ACK for an unrelated owner must not reset phase timing")
        model.acknowledgeSharedSummonForTesting(runId: "run-minutes")
        let generationStarted = try XCTUnwrap(model.minutesActivityPhaseStartedAtForTesting.generation)
        XCTAssertGreaterThanOrEqual(generationStarted, dispatchStarted)
        let generating = try XCTUnwrap(model.minutesActivity(for: active,
                                                             now: generationStarted.addingTimeInterval(3)))
        XCTAssertEqual(generating.label, "AIがこのパートの議事録を生成中")
        XCTAssertEqual(generating.elapsedSeconds, 3)
    }

    func testWrongMinutesModelStopsWithoutRetryAndKeepsCheckpoint() throws {
        let record = meeting()
        model.requestMinutes(for: record)
        let token = try XCTUnwrap(model.summonWatchdogTokenForTesting)
        var job = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        job.completed = [nil]
        try job.save(store: store, id: record.id)
        model.invokeSummonSendFailureForTesting(token: token, source: PetModel.minutesSource,
                                               error: MinutesExecutionTransportError.modelMismatch)
        drainMain()
        XCTAssertNil(model.pendingMinutesMeetingIDForTesting)
        XCTAssertFalse(model.isSummonBusy)
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "failed")
        XCTAssertEqual(MeetingMinutesJob.load(store: store, id: record.id)?.completed.count, 1)
        XCTAssertEqual(model.minutesAttemptsForTesting[record.id], 1)
    }

    func testExplicitRequestsArePrioritizedAndPersistAcrossMetadataRefresh() throws {
        let legacy = MeetingRecord(id: "legacy", source: "meet", startedAt: 1_790_000_000,
                                   endedAt: 1_790_000_100, timeZone: "UTC", title: "legacy",
                                   conferenceCode: nil, participants: [], minutesState: "pending", minutesError: nil)
        let automatic = MeetingRecord(id: "automatic", source: "meet", startedAt: 1_790_000_200,
                                      endedAt: 1_790_000_300, timeZone: "UTC", title: "automatic",
                                      conferenceCode: nil, participants: [], minutesState: "pending", minutesError: nil)
        let explicit = MeetingRecord(id: "explicit", source: "meet", startedAt: 1_790_000_400,
                                     endedAt: 1_790_000_500, timeZone: "UTC", title: "explicit",
                                     conferenceCode: nil, participants: [], minutesState: "pending", minutesError: nil)
        let explicitLater = MeetingRecord(id: "explicit-later", source: "meet", startedAt: 1_789_999_400,
                                          endedAt: 1_789_999_500, timeZone: "UTC", title: "explicit-later",
                                          conferenceCode: nil, participants: [], minutesState: "pending", minutesError: nil)
        [legacy, automatic, explicit, explicitLater].forEach(store.save)
        let envelope = MeetingMinutesEnvelope.build(record: explicit, segments: model.meetingTranscriptProvider?(explicit) ?? [])
        try MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: MeetingMinutes.chunked(envelope),
                              completed: [nil], userRequestedAt: Date(timeIntervalSince1970: 1_790_000_600))
            .save(store: store, id: explicit.id)
        let autoEnvelope = MeetingMinutesEnvelope.build(record: automatic, segments: model.meetingTranscriptProvider?(automatic) ?? [])
        try MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(autoEnvelope), envelopes: MeetingMinutes.chunked(autoEnvelope), completed: [nil])
            .save(store: store, id: automatic.id)
        let legacyEnvelope = MeetingMinutesEnvelope.build(record: legacy, segments: model.meetingTranscriptProvider?(legacy) ?? [])
        try MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(legacyEnvelope), envelopes: MeetingMinutes.chunked(legacyEnvelope), completed: [nil])
            .save(store: store, id: legacy.id)
        let laterEnvelope = MeetingMinutesEnvelope.build(record: explicitLater, segments: model.meetingTranscriptProvider?(explicitLater) ?? [])
        try MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(laterEnvelope), envelopes: MeetingMinutes.chunked(laterEnvelope), completed: [nil],
                              userRequestedAt: Date(timeIntervalSince1970: 1_790_000_700))
            .save(store: store, id: explicitLater.id)

        XCTAssertEqual(PetModel.pendingMinutesOrder([legacy, automatic, explicit, explicitLater], store: store).map(\.id),
                       [explicit.id, explicitLater.id, legacy.id, automatic.id])
        XCTAssertNil(MeetingMinutesJob.load(store: store, id: legacy.id)?.userRequestedAt,
                     "legacy jobs without the key remain automatic FIFO entries")
        var refreshed = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: explicit.id))
        refreshed = refreshed.refreshingMetadata(from: envelope)
        XCTAssertEqual(refreshed.userRequestedAt, Date(timeIntervalSince1970: 1_790_000_600))
        XCTAssertEqual(refreshed.completed.count, 1, "metadata refresh must preserve the checkpoint")
    }
}
