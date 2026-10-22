import Combine
import XCTest
@testable import ClawGate

final class MeetingWorkspaceSnapshotTests: XCTestCase {
    private func record(_ id: String = "meeting") -> MeetingRecord {
        MeetingRecord(id: id, source: "calendar", startedAt: 100, endedAt: 200,
            timeZone: "UTC", title: "Review", conferenceCode: nil, participants: [], minutesState: "ready", minutesError: nil)
    }

    private func context(_ record: MeetingRecord, store: MeetingStore) -> MeetingWorkspaceContext {
        MeetingWorkspaceContext(record: record, store: store, material: nil, pilotLabel: nil, connected: true, activity: nil)
    }

    private func seed(_ record: MeetingRecord, store: MeetingStore, text: String = "Budget approved for the next release") throws {
        store.save(record)
        var segment = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: text)
        segment.capturedAt = 110
        try store.saveBackfill([segment], for: record)
        let envelope = PetModel.minutesEnvelope(for: record, store: store, local: [segment], material: nil)
        let minutes = MeetingMinutes(title: record.title, summary: text, topics: [], decisions: [text], actionItems: [],
            openQuestions: ["Who owns the rollout?"], evidence: [.init(claim: text, segmentIds: ["seg-1"])], attendance: nil, language: "en")
        let accepted = MeetingAcceptedMinutes(minutes: minutes, fingerprint: MeetingMinutesJob.fingerprint(envelope),
            segments: envelope.segments, unresolvedNotes: ["Who owns the rollout?"], createdAt: Date())
        try JSONEncoder().encode(accepted).write(to: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json"), options: .atomic)
    }

    func testBackgroundSnapshotReusesUnchangedDocumentAndStatusOnlyUpdates() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        var meeting = record()
        try seed(meeting, store: store)
        let loader = MeetingWorkspaceLoader()
        let first = try await loader.load(context(meeting, store: store))
        XCTAssertFalse(first.inputsChanged)
        XCTAssertEqual(first.questions, ["Who owns the rollout?"])
        XCTAssertEqual(first.transcriptRows.first?.time, "00:01")
        XCTAssertTrue(first.citedText.values.contains { $0.runs.contains { $0.link?.scheme == "clawgate-segment" } })
        _ = try await loader.load(context(meeting, store: store))
        meeting.minutesState = "failed"
        meeting.minutesError = "Processing failed"
        store.save(meeting)
        let statusOnly = try await loader.load(context(meeting, store: store))
        let count = await loader.preparationCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(statusOnly.record.minutesState, "failed")
        XCTAssertEqual(statusOnly.citedText, first.citedText)
        var changed = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Budget changed for the next release")
        changed.capturedAt = 110
        try store.saveBackfill([changed], for: meeting)
        let updated = try await loader.load(context(meeting, store: store))
        XCTAssertTrue(updated.inputsChanged)
        let updatedCount = await loader.preparationCount
        XCTAssertEqual(updatedCount, 2)
    }

    func testIndexedStatusChangesDoNotPrepareDocumentAgain() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        var meeting = record()
        meeting.minutesState = "pending"
        try seed(meeting, store: store)
        let loader = MeetingWorkspaceLoader()
        _ = try await loader.load(context(meeting, store: store))
        try Data("{}".utf8).write(to: store.directory(for: meeting.id).appendingPathComponent("minutes-execution-test.json"))
        let changed = try await loader.load(context(meeting, store: store))
        XCTAssertNotNil(changed.holdReason)
        let count = await loader.preparationCount
        XCTAssertEqual(count, 1)
    }

    func testOpenAmbientMeetingUsesOneCutoffPerRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root.appendingPathComponent("meetings"))
        let sessions = root.appendingPathComponent("sessions")
        var meeting = record()
        meeting.source = "local"
        meeting.endedAt = nil
        store.save(meeting)
        try writeAmbient("Before cutoff", at: 110, sessionsRoot: sessions)
        let loader = MeetingWorkspaceLoader(sessionsRoot: sessions)
        var clockReads = 0
        let snapshot = try await loader.load(context(meeting, store: store), now: {
            clockReads += 1
            return 200 + Double(clockReads)
        })
        XCTAssertEqual(clockReads, 1)
        XCTAssertEqual(snapshot.transcriptRows.map(\.text), ["Before cutoff"])
        let count = await loader.preparationCount
        XCTAssertEqual(count, 1)
    }

    func testAmbientWriteDuringReadRetriesInsteadOfReturningOldSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root.appendingPathComponent("meetings"))
        let sessions = root.appendingPathComponent("sessions")
        var meeting = record()
        meeting.source = "local"
        meeting.endedAt = nil
        store.save(meeting)
        try writeAmbient("Original", at: 110, sessionsRoot: sessions)
        let loader = MeetingWorkspaceLoader(sessionsRoot: sessions)
        var checkpoints = 0
        let snapshot = try await loader.load(context(meeting, store: store), now: { 200 }, checkingCancellation: {
            try Task.checkCancellation()
            checkpoints += 1
            if checkpoints == 3 { try self.writeAmbient("Updated during read", at: 110, sessionsRoot: sessions) }
        })
        XCTAssertEqual(snapshot.transcriptRows.map(\.text), ["Updated during read"])
        let count = await loader.preparationCount
        XCTAssertEqual(count, 2)
    }

    private func writeAmbient(_ text: String, at capturedAt: Double, sessionsRoot: URL) throws {
        let directory = sessionsRoot.appendingPathComponent("ctx-test/transcripts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var segment = TranscriptSegment(startSeconds: 0, endSeconds: 1, text: text)
        segment.capturedAt = capturedAt
        var data = try JSONEncoder().encode(segment)
        data.append(10)
        try data.write(to: directory.appendingPathComponent("raw.jsonl"), options: .atomic)
    }

    func testNextMeetingAppearingDuringReadInvalidatesTranscriptRange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root.appendingPathComponent("meetings"))
        let sessions = root.appendingPathComponent("sessions")
        var meeting = record()
        meeting.source = "local"
        meeting.endedAt = nil
        store.save(meeting)
        try writeAmbient("Belongs to next meeting", at: 150, sessionsRoot: sessions)
        let loader = MeetingWorkspaceLoader(sessionsRoot: sessions)
        var checkpoints = 0
        let snapshot = try await loader.load(context(meeting, store: store), now: { 200 }, checkingCancellation: {
            try Task.checkCancellation()
            checkpoints += 1
            if checkpoints == 3 {
                var next = self.record("mtg-next")
                next.startedAt = 120
                store.save(next)
            }
        })
        XCTAssertTrue(snapshot.transcriptRows.isEmpty)
        let count = await loader.preparationCount
        XCTAssertEqual(count, 2)
    }

    func testCitationBatchPreservesLinksAndCooperativelyCancels() throws {
        let evidence = [MeetingEvidence(claim: "Budget approved for next release", segmentIds: ["seg-10", "seg-2", "seg-2"], materialIds: ["mat-a"]),
                        MeetingEvidence(claim: "Reference", segmentIds: [], materialIds: ["mat-b", "mat-a"])]
        let index = WorkspaceFormat.CitationIndex(evidence: evidence)
        let text = "Budget, approved for next release. Reference"
        let matches = index.matches(text)
        XCTAssertEqual(matches.segments, ["seg-2", "seg-10"])
        XCTAssertEqual(matches.materials, ["mat-a", "mat-b"])
        let explicit = WorkspaceFormat.cited("Budget approved for next release [seg-2]", allowed: ["seg-2"], index: index)
        XCTAssertTrue(explicit.runs.contains { $0.link?.absoluteString == "clawgate-segment://2" })
        XCTAssertFalse(explicit.runs.contains { $0.link?.absoluteString == "clawgate-segment://2,10" })
        XCTAssertTrue(explicit.runs.contains { $0.link?.absoluteString == "clawgate-material://mat-a" })
        XCTAssertThrowsError(try WorkspaceFormat.CitationIndex(evidence: evidence, checkingCancellation: { throw CancellationError() }))
        XCTAssertThrowsError(try WorkspaceFormat.cited(text, allowed: [], index: index, checkingCancellation: { throw CancellationError() }))
        XCTAssertThrowsError(try WorkspaceFormat.collapseNearDuplicates(["Question"], checkingCancellation: { throw CancellationError() }))
        XCTAssertThrowsError(try MeetingTranscriptFusion.fuse(sourceSegments: [.init(id: "seg-1", source: "local", text: "Speech")], checkingCancellation: { throw CancellationError() }))
    }

    func testChangedRecordIsRejectedRatherThanCombinedWithOldContext() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let original = record()
        try seed(original, store: store)
        var changed = original
        changed.title = "Updated input metadata"
        store.save(changed)
        let loader = MeetingWorkspaceLoader()
        do {
            _ = try await loader.load(context(original, store: store))
            XCTFail("An old context must not be combined with new on-disk metadata")
        } catch MeetingWorkspaceLoadError.changedDuringRead {}
        let latest = try await loader.load(context(changed, store: store))
        XCTAssertEqual(latest.record.title, changed.title)
        XCTAssertFalse(latest.inputsChanged, "The existing input fingerprint intentionally excludes title-only metadata changes")
    }

    @MainActor
    func testRapidABASelectionRejectsCancelledResultsAndCoalescesRefreshes() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let first = record("first"), second = record("second")
        try seed(first, store: store)
        try seed(second, store: store)
        let loader = MeetingWorkspaceLoader()
        let started = expectation(description: "loader blocked away from main")
        let release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await loader.waitForTest(started, release: release) }
        await fulfillment(of: [started], timeout: 2)
        let document = MeetingWorkspaceDocument(loader: loader)
        let applied = expectation(description: "only the last request applies")
        applied.assertForOverFulfill = true
        var appliedIDs: [String] = []
        let observation = document.$snapshot.compactMap { $0?.record.id }.sink { identifier in
            appliedIDs.append(identifier)
            applied.fulfill()
        }
        document.refresh(context(first, store: store))
        document.refresh(context(second, store: store))
        document.refresh(context(first, store: store))
        for _ in 0..<8 { document.refresh(context(first, store: store)) }
        release.signal()
        await blocker.value
        await fulfillment(of: [applied], timeout: 5)
        XCTAssertEqual(appliedIDs, ["first"])
        let count = await loader.preparationCount
        XCTAssertEqual(count, 1)
        observation.cancel()
        document.cancel()
    }
}

private extension MeetingWorkspaceLoader {
    func waitForTest(_ started: XCTestExpectation, release: DispatchSemaphore) {
        started.fulfill()
        _ = release.wait(timeout: .now() + 5)
    }
}
