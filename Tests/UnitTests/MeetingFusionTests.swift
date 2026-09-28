import XCTest
@testable import ClawGate

final class MeetingFusionTests: XCTestCase {
    private var record: MeetingRecord {
        MeetingRecord(id: "mtg-fixture", source: "meet", startedAt: 100, endedAt: 200,
            timeZone: "UTC", title: "Planning", conferenceCode: nil, participants: [],
            minutesState: "pending", minutesError: nil)
    }

    func testFusionKeepsOriginalIDsAndConflictingNumbersButNotUnrelatedSpeechWarnings() {
        var local = TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "Budget is 23 million")
        local.capturedAt = 110; local.speakerName = "Speaker A"
        let external = [
            MeetingTranscriptSourceSegment(id: "meet-a", source: "meet", text: "Budget is 2 million", capturedAt: 111),
            MeetingTranscriptSourceSegment(id: "meet-b", source: "meet", text: "Good afternoon everyone", capturedAt: 110)
        ]
        let result = MeetingTranscriptFusion.fuse(local: [local], external: external)
        XCTAssertEqual(Set(result.segments.map(\.id)), ["seg-1", "meet-a", "meet-b"])
        XCTAssertEqual(result.segments.first { $0.id == "seg-1" }?.speaker, "Speaker A")
        XCTAssertEqual(result.unresolvedNotes.count, 1)
    }

    func testChunkJobsPreserveAllEvidenceAndResumeAfterCheckpoint() throws {
        let input = (0..<20).map {
            MeetingTranscriptSourceSegment(id: "meet-\($0)", source: "meet",
                text: String(repeating: "Discussion ", count: 10), capturedAt: Double(100 + $0))
        }
        let envelope = MeetingMinutesEnvelope.build(record: record, sourceSegments: input)
        let chunks = MeetingMinutes.chunked(envelope, maxCharacters: 500)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.flatMap(\.segments).map(\.id), input.map(\.id))
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let partial = MeetingMinutes(title: "Planning", summary: "Budget discussed", topics: [],
            decisions: [], actionItems: [], openQuestions: [],
            evidence: [MeetingEvidence(claim: "Budget discussed", segmentIds: ["meet-0"])], attendance: nil, language: "en")
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: chunks, completed: [partial])
        try job.save(store: store, id: record.id)
        XCTAssertEqual(MeetingMinutesJob.load(store: store, id: record.id)?.next, chunks[1])
        XCTAssertThrowsError(try store.saveValidatedMinutes(partial, for: record, job: job))
        var complete = job
        complete.completed += Array(repeating: nil, count: chunks.count - 1)
        try store.saveValidatedMinutes(partial, for: record, job: complete)
        XCTAssertEqual(store.loadMinutes(id: record.id), partial)
        XCTAssertEqual(store.loadAcceptedMinutes(id: record.id)?.segments.count, 20)
        // A rejected reply is isolated from the last accepted document.
        store.saveRejectedReply("invalid reply", for: record)
        XCTAssertEqual(store.loadMinutes(id: record.id), partial)
    }

    func testUnknownExternalCitationCannotPassParser() throws {
        let json = """
        {"outcome":"answer","minutes":{"summary":"Claim","topics":[],"decisions":[],"actionItems":[],"openQuestions":[],"evidence":[{"claim":"Claim","segmentIds":["meet-unknown"]}]},"contextDecision":{"policyVersion":"\(MeetingMinutesPrompt.policyVersion)"}}
        """
        XCTAssertThrowsError(try MeetingMinutesParser.parse(json, validSegmentIds: ["meet-known"]))
    }
    func testDuplicateSpeechStillKeepsBothProviderCitationsAndReviewIsBounded() {
        let lines = [
            MeetingTranscriptSourceSegment(id: "seg-1", source: "local", text: "Agreed", capturedAt: 110),
            MeetingTranscriptSourceSegment(id: "meet-1", source: "meet", text: "Agreed", capturedAt: 110)
        ]
        XCTAssertEqual(MeetingTranscriptFusion.fuse(sourceSegments: lines).segments.count, 2)
        let windows = MeetingConflictReview.windows(times: [101, 102, 140, 175, 199], record: record)
        XCTAssertLessThanOrEqual(windows.count, 3)
        XCTAssertTrue(windows.allSatisfy { $0.duration <= 30 && $0.start >= 100 && $0.end <= 200 })
    }

    func testMultipartQueueSkipsEmptyPartAndPublishesOnlyAfterFinalPart() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        store.save(record)
        let model = PetModel()
        model.setMeetingStoreForTesting(store)
        model.setSessionKeyForTesting("test-session")
        model.setConnectionStateForTesting(.connected)
        model.suppressLogSendForTesting = true
        model.meetingTranscriptProvider = { _ in (0..<3).map { _ in
            TranscriptSegment(startSeconds: 0, endSeconds: 1, text: String(repeating: "discussion ", count: 900))
        } }
        model.requestMinutes(for: record)
        XCTAssertEqual(MeetingMinutesJob.load(store: store, id: record.id)?.envelopes.count, 3)
        for _ in 0..<2 {
            model.releaseCurrentSharedSummonForTesting()
            model.completeMinutesReplyForTesting("{\"outcome\":\"insufficientEvidence\",\"minutes\":null,\"contextDecision\":{\"policyVersion\":\"\(MeetingMinutesPrompt.policyVersion)\"}}")
            XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, record.id)
            XCTAssertNil(store.loadAcceptedMinutes(id: record.id))
        }
        model.releaseCurrentSharedSummonForTesting()
        model.completeMinutesReplyForTesting("{\"outcome\":\"answer\",\"minutes\":{\"summary\":\"Discussion\",\"topics\":[],\"decisions\":[],\"actionItems\":[],\"openQuestions\":[],\"evidence\":[{\"claim\":\"Discussion\",\"segmentIds\":[\"seg-3\"]}]},\"contextDecision\":{\"policyVersion\":\"\(MeetingMinutesPrompt.policyVersion)\"}}")
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "ready")
        XCTAssertEqual(store.loadAcceptedMinutes(id: record.id)?.segments.count, 3)
    }

}
