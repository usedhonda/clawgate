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

    func testAFailureFromAnotherRunIsIgnored() throws {
        let record = meeting()
        model.requestMinutes(for: record)
        model.acknowledgeSharedSummonForTesting(runId: "run-mine")
        model.handleEvent(.runFailed(owner: OpenClawEventOwnerIdentity(messageId: "x", runId: "run-other"),
                                     reason: "fence"))
        drainMain()
        XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, record.id)
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
}
