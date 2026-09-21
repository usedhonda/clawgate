import XCTest
@testable import ClawGate

/// Turning the Meet call heartbeat into a durable meeting record. Every test
/// writes into its own temporary directory — never the real ambient store.
final class MeetingRecorderTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawgate-meetings-\(UUID().uuidString)", isDirectory: true)
        store = MeetingStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testFirstHeartbeatStartsAMeetingAndPersistsIt() {
        let recorder = MeetingRecorder(store: store)
        guard case .started(let record) = recorder.heartbeat(inCall: true, now: at(1_000)) else {
            return XCTFail("expected a start edge")
        }
        XCTAssertEqual(record.startedAt, 1_000)
        XCTAssertNil(record.endedAt)
        XCTAssertEqual(record.minutesState, "none")
        XCTAssertEqual(store.load(id: record.id), record)
        XCTAssertEqual(store.all().count, 1)
    }

    func testRepeatedHeartbeatsDoNotStartASecondMeeting() {
        let recorder = MeetingRecorder(store: store)
        recorder.heartbeat(inCall: true, now: at(1_000))
        XCTAssertEqual(recorder.heartbeat(inCall: true, now: at(1_010)), .none)
        XCTAssertEqual(store.all().count, 1)
    }

    func testParticipantsAreTheUnionOfEveryHeartbeat() {
        let recorder = MeetingRecorder(store: store)
        recorder.heartbeat(inCall: true, meta: .init(code: "abc", title: nil, roster: ["田中"]), now: at(1_000))
        // Someone joins late and the first person leaves before the end.
        recorder.heartbeat(inCall: true, meta: .init(code: "abc", title: nil, roster: ["佐藤"]), now: at(1_010))
        guard case .ended(let record) = recorder.heartbeat(inCall: false, now: at(1_020)) else {
            return XCTFail("expected an end edge")
        }
        XCTAssertEqual(record.participants, ["田中", "佐藤"])
    }

    func testEndRunsPastTheLastHeartbeatSoTheClosingWordsSurvive() {
        let recorder = MeetingRecorder(store: store)
        recorder.heartbeat(inCall: true, now: at(1_000))
        recorder.heartbeat(inCall: true, now: at(1_100))
        // The heartbeat stops arriving; the controller's TTL ends the call later.
        guard case .ended(let record) = recorder.heartbeat(inCall: false, now: at(1_140)) else {
            return XCTFail("expected an end edge")
        }
        XCTAssertEqual(record.endedAt, 1_100 + MeetingRecorder.tailSeconds)
        XCTAssertNil(recorder.current)
    }

    func testAHandStartedMeetingEndsWhenItIsStopped() {
        let recorder = MeetingRecorder(store: store)
        recorder.heartbeat(inCall: true, source: "manual", now: at(1_000))
        // No heartbeats arrive for a meeting in a room; the click is the end.
        guard case .ended(let record) = recorder.heartbeat(inCall: false, now: at(4_600)) else {
            return XCTFail("expected an end edge")
        }
        XCTAssertEqual(record.source, "manual")
        XCTAssertEqual(record.endedAt, 4_600 + MeetingRecorder.tailSeconds)
    }

    func testTitleDropsMeetsOwnChromeDecoration() {
        XCTAssertEqual(MeetingHeartbeatMeta.cleanTitle("Meet - Weekly sync", code: "abc-defg-hij"), "Weekly sync")
        XCTAssertEqual(MeetingHeartbeatMeta.cleanTitle("Weekly sync - Google Meet", code: nil), "Weekly sync")
        // An unscheduled call titles the tab with its own code — that is no title.
        XCTAssertNil(MeetingHeartbeatMeta.cleanTitle("Meet - abc-defg-hij", code: "abc-defg-hij"))
        XCTAssertNil(MeetingHeartbeatMeta.cleanTitle("Meet", code: nil))
        XCTAssertNil(MeetingHeartbeatMeta.cleanTitle("   ", code: nil))
    }

    func testTheFirstTitleSeenIsKept() {
        let recorder = MeetingRecorder(store: store)
        recorder.heartbeat(inCall: true, meta: .init(code: "abc", title: "Meet - Weekly sync", roster: []), now: at(1_000))
        recorder.heartbeat(inCall: true, meta: .init(code: "abc", title: "Meet", roster: []), now: at(1_010))
        XCTAssertEqual(recorder.current?.title, "Weekly sync")
        XCTAssertEqual(recorder.current?.conferenceCode, "abc")
    }

    // MARK: - Trimming the tail against the next meeting

    private func record(_ id: String, start: Double, end: Double?) -> MeetingRecord {
        MeetingRecord(id: id, source: "meet", startedAt: start, endedAt: end,
                      timeZone: "UTC", title: nil, conferenceCode: nil,
                      participants: [], minutesState: "none", minutesError: nil)
    }

    func testTheTailStopsAtTheNextMeetingsStart() {
        let first = record("mtg-a", start: 1_000, end: 1_160)   // 1_100 + 60 tail
        let second = record("mtg-b", start: 1_120, end: 1_300)
        XCTAssertEqual(
            AmbientController.trimmedEnd(of: first, against: [first, second], now: 2_000), 1_120)
    }

    func testALoneMeetingKeepsItsWholeTail() {
        let only = record("mtg-a", start: 1_000, end: 1_160)
        XCTAssertEqual(AmbientController.trimmedEnd(of: only, against: [only], now: 2_000), 1_160)
    }

    func testAnOpenMeetingRunsUpToNow() {
        let open = record("mtg-a", start: 1_000, end: nil)
        XCTAssertEqual(AmbientController.trimmedEnd(of: open, against: [open], now: 1_500), 1_500)
    }
}
