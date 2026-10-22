import XCTest
@testable import ClawGate

final class MeetingMinutesPreparationTests: XCTestCase {
    private var store: MeetingStore!
    private var model: PetModel!
    private var record: MeetingRecord!

    override func setUp() {
        super.setUp()
        store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        record = MeetingRecord(id: "mtg-preparation-fixture", source: "manual", startedAt: 1_790_000_000,
            endedAt: 1_790_003_600, timeZone: "UTC", title: "Fixture", conferenceCode: nil,
            participants: [], minutesState: "none", minutesError: nil)
        store.save(record)
        model = PetModel()
        model.setMeetingStoreForTesting(store)
        model.suppressLogSendForTesting = true
    }

    override func tearDown() {
        model.cleanup()
        try? FileManager.default.removeItem(at: store.root)
        super.tearDown()
    }

    private func segment(_ text: String = "fixture") -> TranscriptSegment {
        var segment = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: text)
        segment.capturedAt = record.startedAt + 10
        return segment
    }

    func testRegenerationPreparesOffMainAndCoalescesRepeatedClicks() throws {
        let started = expectation(description: "worker started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let source = segment()
        var reads = 0
        model.meetingTranscriptProvider = { _ in
            XCTAssertFalse(Thread.isMainThread)
            reads += 1
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return [source]
        }
        let acceptedURL = store.directory(for: record.id).appendingPathComponent("minutes.json")
        let accepted = Data("previous accepted artifact".utf8)
        try accepted.write(to: acceptedURL)
        model.regenerateMinutes(for: record)
        XCTAssertTrue(model.preparingMinutesIDs.contains(record.id))
        XCTAssertEqual(model.minutesActivity(for: record)?.label, "議事録の入力を準備中")
        wait(for: [started], timeout: 3)
        for _ in 0..<20 { model.regenerateMinutes(for: record) }
        release.signal()
        waitForMinutesPreparation(of: model)
        XCTAssertEqual(reads, 1)
        let job = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        XCTAssertEqual(job.envelopes.flatMap(\.segments).map(\.text), ["fixture"])
        XCTAssertNotNil(job.userRequestedAt)
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "pending")
        XCTAssertEqual(try Data(contentsOf: acceptedURL), accepted)
        XCTAssertNil(model.pendingMinutesMeetingIDForTesting)
    }

    func testChangedJobCannotBeOverwrittenByPreparation() throws {
        try assertOldPreparationRejected { [self] in
            let envelope = MeetingMinutesEnvelope.build(record: record, segments: [segment("new owner")])
            try MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope),
                envelopes: [envelope], completed: []).save(store: store, id: record.id)
        }
    }

    func testChangedMeetingCannotBeOverwrittenByPreparation() throws {
        try assertOldPreparationRejected { [self] in
            var changed = record!
            changed.minutesState = "ready"
            store.save(changed)
        }
    }

    func testLateTranscriptRevisionCancelsThePreparedInput() throws {
        try assertOldPreparationRejected { [self] in
            let directory = try XCTUnwrap(model.minutesSessionsRootForTesting)
                .appendingPathComponent("ctx-source/transcripts")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var data = try JSONEncoder().encode(segment("late source"))
            data.append(10)
            try data.write(to: directory.appendingPathComponent("raw.jsonl"))
        }
        XCTAssertNotNil(model.minutesPreparationErrors[record.id])
    }

    func testCleanupCancelsPreparationBeforeAnyJobSave() throws {
        let started = expectation(description: "read before cleanup")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let source = segment()
        model.meetingTranscriptProvider = { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return [source]
        }
        model.regenerateMinutes(for: record)
        wait(for: [started], timeout: 3)
        model.cleanup()
        release.signal()
        let finished = expectation(description: "cancelled worker drained")
        model.afterMinutesPreparationForTesting { finished.fulfill() }
        wait(for: [finished], timeout: 5)
        XCTAssertNil(MeetingMinutesJob.load(store: store, id: record.id))
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "none")
        XCTAssertTrue(model.preparingMinutesIDs.isEmpty)
    }

    func testIndexedOwnerCreatedDuringDrainPreventsDispatch() throws {
        record.minutesState = "pending"
        store.save(record)
        let envelope = MeetingMinutesEnvelope.build(record: record, segments: [segment()])
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: [envelope], completed: [])
        try job.save(store: store, id: record.id)
        let jobURL = store.directory(for: record.id).appendingPathComponent("minutes-job.json")
        let frozen = try Data(contentsOf: jobURL)
        model.setSessionKeyForTesting("agent:fixture:main")
        model.setConnectionStateForTesting(.connected)
        let built = expectation(description: "dispatch snapshot built off main")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.minutesDrainDidBuildForTesting = {
            XCTAssertFalse(Thread.isMainThread)
            built.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        model.drainMinutesForTesting()
        wait(for: [built], timeout: 3)
        model.minutesDrainDidBuildForTesting = nil
        var ledger = try MeetingMinutesExecutionState(job: job)
        _ = try ledger.reserve(index: 0, sessionKey: "agent:fixture:main", message: "fixture", store: store, id: record.id)
        release.signal()
        waitForMinutesPreparation(of: model)
        XCTAssertNil(model.pendingMinutesMeetingIDForTesting)
        XCTAssertEqual(model.minutesAttemptsForTesting[record.id, default: 0], 0)
        XCTAssertEqual(try Data(contentsOf: jobURL), frozen)
    }

    func testLegacyPendingWithoutTranscriptFailsInsteadOfRemainingPending() {
        var pending = record!
        pending.minutesState = "pending"
        store.save(pending)
        model.meetingTranscriptProvider = { _ in [] }
        model.setSessionKeyForTesting("agent:fixture:main")
        model.setConnectionStateForTesting(.connected)
        model.drainMinutesForTesting()
        waitForMinutesPreparation(of: model)
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "failed")
        XCTAssertNotNil(store.load(id: record.id)?.minutesError)
        XCTAssertNil(model.pendingMinutesMeetingIDForTesting)
        XCTAssertNil(MeetingMinutesJob.load(store: store, id: record.id))
    }

    func testJobCreatedAfterPreparationFailureCannotBeMarkedFailed() throws {
        let built = expectation(description: "failure computed before replacement")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.meetingTranscriptProvider = { _ in [] }
        model.minutesPreparationDidBuildForTesting = {
            built.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        model.requestMinutes(for: record)
        wait(for: [built], timeout: 3)
        model.minutesPreparationDidBuildForTesting = nil
        let envelope = MeetingMinutesEnvelope.build(record: record, segments: [segment("new revision")])
        try MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope),
            envelopes: [envelope], completed: []).save(store: store, id: record.id)
        let jobURL = store.directory(for: record.id).appendingPathComponent("minutes-job.json")
        let expected = try Data(contentsOf: jobURL)
        release.signal()
        waitForMinutesPreparation(of: model)
        XCTAssertEqual(store.load(id: record.id), record)
        XCTAssertEqual(try Data(contentsOf: jobURL), expected)
        XCTAssertNotNil(model.minutesPreparationErrors[record.id])
        XCTAssertNil(model.pendingMinutesMeetingIDForTesting)
    }

    private func assertOldPreparationRejected(mutate: () throws -> Void) throws {
        let initial = MeetingMinutesEnvelope.build(record: record, segments: [segment("old job")])
        try MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(initial), envelopes: [initial], completed: [])
            .save(store: store, id: record.id)
        let started = expectation(description: "read before state change")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let source = segment()
        model.meetingTranscriptProvider = { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return [source]
        }
        model.regenerateMinutes(for: record)
        wait(for: [started], timeout: 3)
        try mutate()
        let jobURL = store.directory(for: record.id).appendingPathComponent("minutes-job.json")
        let expected = try Data(contentsOf: jobURL)
        let expectedRecord = store.load(id: record.id)
        release.signal()
        waitForMinutesPreparation(of: model)
        XCTAssertEqual(try Data(contentsOf: jobURL), expected)
        XCTAssertEqual(store.load(id: record.id), expectedRecord)
        XCTAssertNil(model.pendingMinutesMeetingIDForTesting)
    }
}
