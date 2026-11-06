import XCTest
@testable import ClawGate

final class MeetingFusionTests: XCTestCase {
    func testConsistentClockShiftRetainsOriginalEvidenceAndDetectsConflict() {
        let anchors = ["The first shared sentence", "The second shared sentence", "The third shared sentence"]
        let local = anchors.enumerated().map {
            MeetingTranscriptSourceSegment(id: "l\($0.offset)", source: "local", text: $0.element, capturedAt: Double($0.offset * 10 + 100))
        } + [.init(id: "budget-local", source: "local", text: "Budget is 23 million", capturedAt: 140)]
        let remote = anchors.enumerated().map {
            MeetingTranscriptSourceSegment(id: "r\($0.offset)", source: "meet", text: $0.element, capturedAt: Double($0.offset * 10 + 160))
        } + [.init(id: "budget-remote", source: "meet", text: "Budget is 2 million", capturedAt: 200)]
        let fused = MeetingTranscriptFusion.fuse(sourceSegments: local + remote)
        XCTAssertEqual(fused.clockOffsetsBySource["meet:"], -60)
        XCTAssertEqual(fused.segments.count, 8)
        XCTAssertEqual(fused.segments.first { $0.id == "budget-remote" }?.capturedAt, 200)
        XCTAssertEqual(fused.unresolvedNotes.count, 1)
        XCTAssertEqual(fused.provenanceBySegmentID["l0"], ["l0", "r0"])
    }

    func testClockShiftRequiresUniqueOrderedConsistentAnchors() {
        let text = ["A long shared first utterance", "A long shared second utterance", "A long shared third utterance"]
        let local = text.enumerated().map {
            MeetingTranscriptSourceSegment(id: "l\($0.offset)", source: "local", text: $0.element, capturedAt: Double($0.offset * 10))
        }
        let drift = text.enumerated().map {
            MeetingTranscriptSourceSegment(id: "r\($0.offset)", source: "meet", text: $0.element, capturedAt: Double($0.offset * 20 + 60))
        }
        XCTAssertTrue(MeetingTranscriptFusion.fuse(sourceSegments: local + drift).clockOffsetsBySource.isEmpty)
        XCTAssertTrue(MeetingTranscriptFusion.fuse(sourceSegments: Array(local.prefix(2)) + Array(drift.prefix(2))).clockOffsetsBySource.isEmpty)
        let untimed = MeetingTranscriptSourceSegment(id: "untimed", source: "recall", text: text[0])
        XCTAssertNil(MeetingTranscriptFusion.fuse(sourceSegments: local + [untimed]).segments.last?.capturedAt)
    }

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

    func testSelectedIntegrationUsesWiderChunksAndStillRequiresWholeMeetingReconciliation() {
        let input = (0..<4).map {
            MeetingTranscriptSourceSegment(id: "source-\($0)", source: "meet",
                text: String(repeating: "evidence ", count: 750), capturedAt: Double(100 + $0))
        }
        let ordinary = MeetingMinutesEnvelope.build(record: record, sourceSegments: input)
        var selected = ordinary
        selected.integrationSelectionFingerprint = "selected-fixture"
        let selectedChunks = MeetingMinutes.chunked(selected)
        XCTAssertEqual(selectedChunks.count, 1)
        XCTAssertEqual(MeetingMinutes.chunked(ordinary).count, 2)
        XCTAssertEqual(MeetingMinutes.chunked(selected, maxCharacters: 16_000).count, 2)
        XCTAssertEqual(selectedChunks.flatMap(\.segments).map(\.id), ordinary.segments.map(\.id))
        XCTAssertEqual(selectedChunks.flatMap(\.segments).map(\.text), ordinary.segments.map(\.text))
        let selectedJob = MeetingMinutesJob(fingerprint: "selected", envelopes: selectedChunks, completed: [])
        let ordinaryJob = MeetingMinutesJob(fingerprint: "ordinary", envelopes: [ordinary], completed: [])
        XCTAssertTrue(MeetingMinutesSummaryPass.needed(for: selectedJob))
        XCTAssertFalse(MeetingMinutesSummaryPass.needed(for: ordinaryJob))
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

    func testExternalOffsetsSurviveAcceptanceWithoutInventingCaptureTime() throws {
        let lineage = MeetingRecallTranscriptLineage(
            eventID: "00000000-0000-0000-0000-000000000001",
            resultID: "00000000-0000-0000-0000-000000000002", processingVersion: "local-stt-v1",
            parents: [.init(source: "recall", externalID: "fixture-original",
                            eventID: "00000000-0000-0000-0000-000000000003")], segmentIndex: 1)
        let original = MeetingTranscriptSourceSegment(id: "recall-fixture-1", source: "recall",
            text: "A grounded statement", sourceLocator: "segment:1",
            startSeconds: 3.5, endSeconds: 9.5, recallLineage: lineage)
        let fused = MeetingTranscriptFusion.fuse(local: [], external: [original])
        let envelope = MeetingMinutesEnvelope.build(record: record, sourceSegments: fused.segments)
        let chunks = MeetingMinutes.chunked(envelope, maxCharacters: 500)
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let minutes = MeetingMinutes(title: "Planning", summary: "A grounded statement", topics: [],
            decisions: [], actionItems: [], openQuestions: [],
            evidence: [MeetingEvidence(claim: "A grounded statement", segmentIds: [original.id])],
            attendance: nil, language: "en")
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope),
            envelopes: chunks, completed: [minutes])
        try job.save(store: store, id: record.id)
        try store.saveValidatedMinutes(minutes, for: record, job: job)
        let persisted = try XCTUnwrap(store.loadAcceptedMinutes(id: record.id)?.segments.first)
        XCTAssertEqual(persisted.startSeconds, 3.5)
        XCTAssertEqual(persisted.endSeconds, 9.5)
        XCTAssertNil(persisted.capturedAt)
        XCTAssertEqual(persisted.source, "recall")
        XCTAssertEqual(persisted.sourceLocator, "segment:1")
        XCTAssertEqual(persisted.recallLineage, lineage)
        let snapshot = try MeetingMinutesKnowledgeSnapshot(
            acceptedData: Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json")), record: record)
        XCTAssertEqual(snapshot.citations.first?.recallLineage, lineage)
        XCTAssertEqual(MeetingMinutesJob.load(store: store, id: record.id)?.envelopes.first?.segments.first, persisted)
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
        model.setSessionKeyForTesting("agent:main:main")
        model.setConnectionStateForTesting(.connected)
        let finalDispatched = expectation(description: "retained final request reserved")
        let finalCompleted = expectation(description: "retained final result published")
        var requestSent: MinutesExecutionSendParams?
        model.minutesFinalDidFinishForTesting = { finalCompleted.fulfill() }
        model.minutesFinalTransportForTesting = (
            send: { request in
                XCTAssertNil(requestSent, "lost ACK must not cause another send")
                XCTAssertEqual(request.sessionKey, "agent:main:main")
                requestSent = request
                finalDispatched.fulfill()
                throw URLError(.networkConnectionLost)
            },
            read: { request in
                XCTAssertEqual(requestSent, request)
                let body = """
                {"policyVersion":"\(MeetingMinutesSummaryPass.policyVersion)",
                 "minutes":{"summary":"Discussion","topics":[],"decisions":[],"actionItems":[],"openQuestions":[],"evidence":[{"claim":"Discussion","segmentIds":["seg-3"]}]},
                 "resolutions":[{"sourceClaimIds":["part-0-summary-0"],"disposition":"retained","outputClaims":["Discussion"],"quotes":[]}]}
                """
                let binding: [String: Any] = ["version": 1, "requestFingerprintScheme": MinutesRequestFingerprint.scheme,
                    "requestFingerprint": try request.requestFingerprint(), "resolvedModel": MinutesExecutionSendParams.model,
                    "resolvedThinking": "high", "degraded": false, "fallbackReason": NSNull(),
                    "isolationApplied": true, "nonprojectionApplied": true, "retentionApplied": true]
                let object: [String: Any] = ["status": "terminal", "sessionKey": request.sessionKey,
                    "runId": request.idempotencyKey, "executionBinding": binding,
                    "terminal": ["kind": "answer", "answer": body], "resultRetentionExpiresAt": 1_800_000_000_000]
                return try MinutesExecutionRead.validate(JSONDecoder().decode(IncomingPayload.self,
                    from: JSONSerialization.data(withJSONObject: object)), expected: request)
            })
        model.suppressLogSendForTesting = true
        let originalGap = PetModel.minutesPartGapSeconds
        PetModel.minutesPartGapSeconds = 0
        defer { PetModel.minutesPartGapSeconds = originalGap }
        model.meetingTranscriptProvider = { _ in (0..<3).map { _ in
            TranscriptSegment(startSeconds: 0, endSeconds: 1, text: String(repeating: "discussion ", count: 900))
        } }
        model.requestMinutes(for: record)
        waitForMinutesPreparation(of: model)
        XCTAssertEqual(MeetingMinutesJob.load(store: store, id: record.id)?.envelopes.count, 3)
        for _ in 0..<2 {
            model.releaseCurrentSharedSummonForTesting()
            model.completeMinutesReplyForTesting("{\"outcome\":\"insufficientEvidence\",\"minutes\":null,\"contextDecision\":{\"policyVersion\":\"\(MeetingMinutesPrompt.policyVersion)\"}}")
            waitForMinutesPreparation(of: model)
            XCTAssertEqual(model.pendingMinutesMeetingIDForTesting, record.id)
            XCTAssertNil(store.loadAcceptedMinutes(id: record.id))
        }
        model.releaseCurrentSharedSummonForTesting()
        model.completeMinutesReplyForTesting("{\"outcome\":\"answer\",\"minutes\":{\"summary\":\"Discussion\",\"topics\":[],\"decisions\":[],\"actionItems\":[],\"openQuestions\":[],\"evidence\":[{\"claim\":\"Discussion\",\"segmentIds\":[\"seg-3\"]}]},\"contextDecision\":{\"policyVersion\":\"\(MeetingMinutesPrompt.policyVersion)\"}}")
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "pending")
        XCTAssertNil(store.loadAcceptedMinutes(id: record.id))
        waitForMinutesPreparation(of: model)
        wait(for: [finalDispatched], timeout: 2)
        XCTAssertFalse(model.isSummonBusy, "final pass does not own ordinary chat")
        XCTAssertNil(store.loadAcceptedMinutes(id: record.id))
        wait(for: [finalCompleted], timeout: 8)
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "ready")
        XCTAssertEqual(store.loadAcceptedMinutes(id: record.id)?.segments.count, 3)

        let savedJob = try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-job.json"))
        var failedFinal = try XCTUnwrap(store.load(id: record.id))
        failedFinal.minutesState = "failed"
        store.save(failedFinal)
        let resumedFinal = expectation(description: "completed-part final pass resumes without regeneration")
        model.minutesFinalDidFinishForTesting = { resumedFinal.fulfill() }
        model.meetingTranscriptProvider = { _ in XCTFail("resume must use frozen parts"); return [] }
        model.resumeMinutes(for: failedFinal)
        wait(for: [resumedFinal], timeout: 3)
        XCTAssertEqual(store.load(id: record.id)?.minutesState, "ready")
        XCTAssertEqual(try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-job.json")), savedJob)
    }

}
