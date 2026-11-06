import XCTest
import CryptoKit
@testable import ClawGate

final class MeetingMinutesOverviewExecutorTests: XCTestCase {
    func testLostAckThenReadPublishesOnceAndReopenDoesNotSend() async throws {
        let record = MeetingRecord(id: "overview-fixture", source: "manual", startedAt: 0,
                                   endedAt: 20, timeZone: "UTC", title: "Fixture",
                                   conferenceCode: nil, participants: [], minutesState: "pending", minutesError: nil)
        let envelope = MeetingMinutesEnvelope.build(record: record,
            segments: (0..<5).map { index in
                TranscriptSegment(startSeconds: Double(index), endSeconds: Double(index + 1),
                                  text: String(repeating: String(index), count: 160))
            })
        let envelopes = MeetingMinutes.chunked(envelope, maxCharacters: 120)
        XCTAssertEqual(envelopes.count, 5)
        XCTAssertEqual(MeetingMinutesSummaryPass.stages(partCount: 5), [[0, 1], [2, 3], [5, 6], [7, 4]])
        let answers = envelopes.enumerated().map { index, part in
            let summary = "Part \(index + 1)"
            return MeetingMinutes(title: "Fixture", summary: summary, topics: [], decisions: [],
                actionItems: [], openQuestions: [],
                evidence: [MeetingEvidence(claim: summary, segmentIds: part.segments.map(\.id))],
                attendance: nil, language: nil)
        }
        let fingerprint = MeetingMinutesJob.fingerprint(envelope)
        let frozen = MeetingMinutesJob(fingerprint: fingerprint, envelopes: envelopes,
                                       completed: [])
        let completed = MeetingMinutesJob(fingerprint: fingerprint, envelopes: envelopes,
                                          completed: answers)
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        try frozen.save(store: store, id: record.id)
        let base = try XCTUnwrap(MeetingMinutes.combining(answers)?.boundToCalendarEvent(record.calendarEventID))
        XCTAssertNil(store.loadAcceptedMinutes(id: record.id))

        actor Wire {
            var sends = 0
            let evidenceSegmentID: String
            var invalid = false
            let requiresCorrection: Bool
            var requests: [MinutesExecutionSendParams] = []
            init(evidenceSegmentID: String, requiresCorrection: Bool = false) {
                self.evidenceSegmentID = evidenceSegmentID; self.requiresCorrection = requiresCorrection
            }
            func send(_ request: MinutesExecutionSendParams) async throws -> MinutesExecutionAck {
                sends += 1
                requests.append(request)
                throw URLError(.networkConnectionLost)
            }
            func count() -> Int { sends }
            func sentRequests() -> [MinutesExecutionSendParams] { requests }
            func invalidate() { invalid = true }
            func read(_ request: MinutesExecutionSendParams, maximumParts: Int = 2) async throws -> MinutesExecutionRead {
                let json = try XCTUnwrap(request.message.components(separatedBy: "\n\n").last)
                let input = try JSONDecoder().decode(MeetingMinutesSummaryPass.Input.self, from: Data(json.utf8))
                XCTAssertLessThanOrEqual(input.parts.count, maximumParts)
                XCTAssertEqual(Set(input.segments.map(\.id)), Set(input.claims.flatMap(\.segmentIds)))
                let minutes = MeetingMinutes(title: "Fixture", summary: "全体の概要。", topics: [], decisions: [],
                    actionItems: [], openQuestions: [], evidence: [.init(claim: "全体の概要。", segmentIds: Array(Set(input.claims.flatMap(\.segmentIds))).sorted())],
                    attendance: nil, language: nil)
                let unsupported = requiresCorrection && !request.message.contains("[" + MeetingMinutesSummaryPass.correctionVersion + "]")
                let reply = MeetingMinutesSummaryPass.Reply(policyVersion: invalid ? "wrong" : MeetingMinutesSummaryPass.policyVersion,
                    minutes: minutes, resolutions: [.init(sourceClaimIds: input.claims.map(\.id),
                        disposition: unsupported ? "corrected" : "merged", outputClaims: [minutes.summary],
                        quotes: unsupported ? [.init(segmentId: evidenceSegmentID, text: "unsupported correction")] : [])])
                let body = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
                let binding: [String: Any] = ["version": 1, "requestFingerprintScheme": MinutesRequestFingerprint.scheme,
                    "requestFingerprint": try request.requestFingerprint(), "resolvedModel": MinutesExecutionSendParams.model,
                    "resolvedThinking": "high", "degraded": false, "fallbackReason": NSNull(),
                    "isolationApplied": true, "nonprojectionApplied": true, "retentionApplied": true]
                let object: [String: Any] = ["status": "terminal", "sessionKey": request.sessionKey,
                    "runId": request.idempotencyKey, "executionBinding": binding, "terminal": ["kind": "answer", "answer": body],
                    "resultRetentionExpiresAt": 1_800_000_000_000]
                return try MinutesExecutionRead.validate(
                    JSONDecoder().decode(IncomingPayload.self, from: JSONSerialization.data(withJSONObject: object)),
                    expected: MinutesExecutionSendParams(sessionKey: request.sessionKey, message: request.message, idempotencyKey: request.idempotencyKey))
            }
        }
        let wire = Wire(evidenceSegmentID: try XCTUnwrap(envelopes.first?.segments.first?.id))
        let first = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: store, id: record.id, sessionKey: "agent:overview:main",
            send: { try await wire.send($0) }, read: { try await wire.read($0) })
        let firstState = try await first.step()
        XCTAssertEqual(firstState, .recovering)
        XCTAssertNil(store.loadAcceptedMinutes(id: record.id))
        var result: MeetingMinutes?
        for stage in 0..<(answers.count - 1) {
            let reopened = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
                record: record, store: store, id: record.id, sessionKey: "agent:overview:main",
                send: { _ in XCTFail("recovery must not send"); throw URLError(.badServerResponse) },
                read: { try await wire.read($0) })
            let state = try await reopened.step()
            if stage == answers.count - 2 {
                guard case .completed(let rewritten?) = state else { return XCTFail("final stage must publish") }
                result = rewritten
            } else {
                XCTAssertEqual(state, .pending)
                XCTAssertNil(store.loadAcceptedMinutes(id: record.id), "intermediate stage must stay private")
                let next = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
                    record: record, store: store, id: record.id, sessionKey: "agent:overview:main",
                    send: { try await wire.send($0) },
                    read: { _ in XCTFail("completed stage must not read again"); throw URLError(.badServerResponse) })
                let nextState = try await next.step()
                XCTAssertEqual(nextState, .recovering)
            }
        }
        let rewritten = try XCTUnwrap(result)
        XCTAssertEqual(rewritten.summary, "全体の概要。")
        XCTAssertEqual(Set((rewritten.evidence ?? []).flatMap(\.segmentIds)), Set(envelope.segments.map(\.id)))
        let sendCount = await wire.count()
        XCTAssertEqual(sendCount, answers.count - 1)

        let acceptedBytes = try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json"))
        var editedRecord = record
        editedRecord.startedAt += 86_400
        editedRecord.timeZone = "Asia/Tokyo"
        editedRecord.title = "Later calendar metadata"
        editedRecord.calendarEventID = "later-calendar"
        let afterComplete = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: editedRecord, store: store, id: record.id, sessionKey: "agent:overview:main",
            send: { _ in XCTFail("completed overview must not send"); throw URLError(.badServerResponse) },
            read: { _ in XCTFail("completed overview must not read"); throw URLError(.badServerResponse) })
        let repeated = try await afterComplete.step()
        guard case .completed(let same?) = repeated else { return XCTFail("published overview must reopen") }
        XCTAssertEqual(same, rewritten)
        XCTAssertEqual(try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json")), acceptedBytes)

        let invalidStore = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: invalidStore.root) }
        try frozen.save(store: invalidStore, id: record.id)
        try invalidStore.saveValidatedMinutes(base, for: record, job: completed)
        let invalidPath = invalidStore.directory(for: record.id).appendingPathComponent("minutes-accepted.json")
        let beforeInvalid = try Data(contentsOf: invalidPath)
        let invalidWire = Wire(evidenceSegmentID: try XCTUnwrap(envelopes.first?.segments.first?.id))
        await invalidWire.invalidate()
        let invalidExecutor = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: invalidStore, id: record.id, sessionKey: "agent:overview:main",
            send: { try await invalidWire.send($0) }, read: { try await invalidWire.read($0) })
        _ = try await invalidExecutor.step()
        let rejected = try await invalidExecutor.step()
        XCTAssertEqual(rejected, .failed)
        XCTAssertEqual(try Data(contentsOf: invalidPath), beforeInvalid)

        let stillInvalid = try await invalidExecutor.step()
        XCTAssertEqual(stillInvalid, .failed)
        let invalidSends = await invalidWire.count()
        XCTAssertEqual(invalidSends, 1, "revalidation never sends another request")
        XCTAssertEqual(try Data(contentsOf: invalidPath), beforeInvalid)

        let correctionStore = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: correctionStore.root) }
        try frozen.save(store: correctionStore, id: record.id)
        try correctionStore.saveValidatedMinutes(base, for: record, job: completed)
        let correctionAccepted = correctionStore.directory(for: record.id).appendingPathComponent("minutes-accepted.json")
        let correctionBefore = try Data(contentsOf: correctionAccepted)
        let correctionWire = Wire(evidenceSegmentID: try XCTUnwrap(envelopes.first?.segments.first?.id), requiresCorrection: true)
        let rejectedOwner = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: correctionStore, id: record.id, sessionKey: "agent:overview:main",
            send: { try await correctionWire.send($0) }, read: { try await correctionWire.read($0) })
        _ = try await rejectedOwner.step()
        let evidenceRejected = try await rejectedOwner.step()
        XCTAssertEqual(evidenceRejected, .failed)
        let withoutExplicitResume = try await rejectedOwner.step()
        XCTAssertEqual(withoutExplicitResume, .failed)
        let originalSends = await correctionWire.count()
        XCTAssertEqual(originalSends, 1)
        let explicitResume = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: correctionStore, id: record.id, sessionKey: "agent:overview:main",
            send: { try await correctionWire.send($0) }, read: { try await correctionWire.read($0) }, correctionRequested: true)
        let correctiveSend = try await explicitResume.step()
        XCTAssertEqual(correctiveSend, .recovering, "lost ACK leaves the correction reserved")
        let sent = await correctionWire.sentRequests()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].idempotencyKey, MeetingMinutesExecutionState.answerCorrectionKey(rejectedKey: sent[0].idempotencyKey))
        XCTAssertEqual(sent[1].message.components(separatedBy: "\n\n").last,
                       sent[0].message.components(separatedBy: "\n\n").last, "fixed original input remains exact")
        let correctionReopen = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: correctionStore, id: record.id, sessionKey: "agent:overview:main",
            send: { _ in XCTFail("reserved correction only reads"); throw URLError(.badServerResponse) },
            read: { try await correctionWire.read($0) }, correctionRequested: true)
        let correctedStage = try await correctionReopen.step()
        XCTAssertEqual(correctedStage, .pending)
        XCTAssertEqual(try Data(contentsOf: correctionAccepted), correctionBefore)

        // A pre-tree deployment may already own a retained single request.
        // Reopening must consume that exact request, not dispatch a new tree.
        let legacyStore = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: legacyStore.root) }
        try frozen.save(store: legacyStore, id: record.id)
        let frozenEnvelope = try XCTUnwrap(completed.frozenEnvelope)
        let originalInput = MeetingMinutesSummaryPass.input(for: base, parts: answers, record: record, segments: frozenEnvelope.segments)
        struct LegacyFingerprint: Encodable {
            let domain: String; let original: String; let envelopeHashes: [String]
            let envelope: MeetingMinutesEnvelope; let base: MeetingMinutes; let input: MeetingMinutesSummaryPass.Input
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacyBytes = try encoder.encode(LegacyFingerprint(domain: "overview-v1", original: frozen.fingerprint,
            envelopeHashes: try envelopes.map(MeetingMinutesExecutionState.hash), envelope: frozenEnvelope,
            base: base, input: originalInput))
        let legacyJob = MeetingMinutesJob(fingerprint: SHA256.hash(data: legacyBytes).map { String(format: "%02x", $0) }.joined(),
            envelopes: [frozenEnvelope], completed: [], supplementalSnapshot: frozenEnvelope.supplementalMaterials)
        var legacyLedger = try MeetingMinutesExecutionState(job: legacyJob)
        let reserved = try legacyLedger.reserve(index: 0, sessionKey: "agent:overview:main",
            message: MeetingMinutesSummaryPass.buildMessage(input: originalInput), store: legacyStore, id: record.id)
        // Simulate a prior validator rejecting an otherwise grounded retained
        // result. Upgrade recovery must revalidate the exact immutable owner.
        let retained = try await wire.read(reserved.request, maximumParts: 5)
        try legacyLedger.reconcile(reserved, read: retained, store: legacyStore, id: record.id)
        try legacyLedger.failTerminal(reserved, runId: reserved.idempotencyKey,
            code: "invalid_answer", retryable: false, store: legacyStore, id: record.id)
        let legacyExecutor = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: legacyStore, id: record.id, sessionKey: "agent:overview:main",
            send: { _ in XCTFail("upgrade must not create a second owner"); throw URLError(.badServerResponse) },
            read: { request in
                XCTAssertEqual(request, reserved.request)
                return try await wire.read(request, maximumParts: 5)
            })
        let legacyResult = try await legacyExecutor.step()
        guard case .completed = legacyResult else { return XCTFail("existing owner must finish on its original protocol") }
        let recovered = try XCTUnwrap(MeetingMinutesExecutionState.load(store: legacyStore, id: record.id, job: legacyJob))
        XCTAssertEqual(recovered.parts[0].status, .completed)
        XCTAssertEqual(recovered.parts[0].attempt, 1)
        XCTAssertEqual(recovered.parts[0].request, reserved.request)
        XCTAssertEqual(recovered.parts[0].executionBinding, retained.binding)

        let changedJob = MeetingMinutesJob.updating(envelope, previous: frozen)
        try changedJob.save(store: store, id: record.id)
        let stale = try MeetingMinutesOverviewExecutor(frozenJob: frozen, completedJob: completed,
            record: record, store: store, id: record.id, sessionKey: "agent:overview:main",
            send: { _ in XCTFail("stale overview must not send"); throw URLError(.badServerResponse) },
            read: { _ in XCTFail("stale overview must not read"); throw URLError(.badServerResponse) })
        do {
            _ = try await stale.step()
            XCTFail("stale overview publication must be rejected")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json")), acceptedBytes)
    }
}
