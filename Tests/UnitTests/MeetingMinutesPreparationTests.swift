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

    func testSelectedRecallRequiresFreshReadAndKeepsEvidenceInNormalJob() throws {
        let selections = MeetingRecallSelectionStore(store: store)
        let event = "00000000-0000-4000-8000-000000000001"
        let selected = try selections.save(items: [.init(eventID: event, resultEventID: nil)],
            record: record, expectedFingerprint: nil)
        let fingerprint = try XCTUnwrap(selected.fingerprint)
        let evidence = MeetingTranscriptSourceSegment(id: "recall-fixture", source: "recall",
            text: "Selected statement", sourceLocator: "Hub event " + event)
        let fresh = MeetingMinutesPreparation.RecallInput(selectionFingerprint: fingerprint,
            segments: [evidence], coverageHints: ["Coverage is unconfirmed"])
        func input(_ recall: MeetingMinutesPreparation.RecallInput?,
                   transcript: ((MeetingRecord) -> [TranscriptSegment])? = nil) -> MeetingMinutesPreparation.Input {
            .init(record: record, store: store, sessionsRoot: store.root.appendingPathComponent("sessions"),
                material: nil, transcript: transcript, preservingMaterials: false,
                refreshPreparedInput: false, regenerate: true, forceFull: false, recall: recall)
        }
        func run(_ input: MeetingMinutesPreparation.Input) throws {
            _ = try MeetingMinutesPreparation.run(input, ticket: .init(requestedAt: Date()))
        }
        XCTAssertThrowsError(try run(input(nil, transcript: { [self] _ in [segment()] }))) {
            guard case MeetingMinutesPreparation.Failure.recallReadRequired = $0 else {
                return XCTFail("Selected evidence must not silently fall back to local speech")
            }
        }
        XCTAssertNil(MeetingMinutesJob.load(store: store, id: record.id))
        let stale = MeetingMinutesPreparation.RecallInput(selectionFingerprint: "sha256:stale",
            segments: [evidence], coverageHints: [])
        XCTAssertThrowsError(try run(input(stale)))
        XCTAssertThrowsError(try run(input(fresh, transcript: { [self] _ in
            _ = try? selections.save(items: [], record: record, expectedFingerprint: fingerprint)
            return []
        }))) {
            guard case MeetingMinutesPreparation.Failure.changed = $0 else { return XCTFail("Changed selection accepted") }
        }
        XCTAssertNil(MeetingMinutesJob.load(store: store, id: record.id))
        let empty = try selections.load(meetingID: record.id)
        let restored = try selections.save(items: selected.items, record: record, expectedFingerprint: empty.fingerprint)
        let current = MeetingMinutesPreparation.RecallInput(selectionFingerprint: try XCTUnwrap(restored.fingerprint),
            segments: [evidence], coverageHints: fresh.coverageHints)
        try run(input(current))
        let job = try XCTUnwrap(MeetingMinutesJob.load(store: store, id: record.id))
        let envelope = try XCTUnwrap(job.envelopes.first)
        XCTAssertEqual(envelope.segments.map(\.id), [evidence.id])
        XCTAssertEqual(envelope.segments.first?.source, "recall")
        XCTAssertEqual(envelope.segments.first?.sourceLocator, evidence.sourceLocator)
        XCTAssertNil(envelope.segments.first?.capturedAt)
        XCTAssertEqual(envelope.coverageHints, fresh.coverageHints)
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
