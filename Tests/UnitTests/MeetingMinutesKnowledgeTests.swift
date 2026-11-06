import XCTest
@testable import ClawGate

final class MeetingMinutesKnowledgeTests: XCTestCase {
    func testSupersessionKeepsExactBodyAndIndependentReceiptsUntilExplicitRestore() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let old = record("old"), target = record("target")
        let oldBytes = try accepted(old), targetBytes = try accepted(target)
        var queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        let other = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024,
            directoryName: "knowledge-outbox-hub", sourceUUID: queue.sourceUUID, compactsWhenStored: true)
        for q in [queue, other] {
            try q.enqueue(acceptedData: oldBytes, record: old)
            try q.enqueue(acceptedData: targetBytes, record: target)
        }
        let originals = try queue.publications()
        let source = try XCTUnwrap(originals.first { $0.meetingID == old.id })
        let destination = try XCTUnwrap(originals.first { $0.meetingID == target.id })
        let data = try XCTUnwrap(Data(base64Encoded: source.payloadBase64))
        let pointer = MeetingMinutesPublication.SupersededBy(sourceUUID: queue.sourceUUID,
            meetingID: target.id, outputRevision: destination.outputRevision)
        XCTAssertThrowsError(try queue.enqueueSupersession(snapshotData: data, meetingID: old.id, expectedOrdinal: 1, target: pointer))
        for item in originals { try queue.receive(receipt(item, status: .searchable), expected: item) }
        try queue.enqueueSupersession(snapshotData: data, meetingID: old.id, expectedOrdinal: 1, target: pointer)
        let publication = try XCTUnwrap(queue.publications().first)
        XCTAssertEqual(publication.publicationOrdinal, 2)
        XCTAssertEqual(publication.payloadBase64, source.payloadBase64)
        XCTAssertEqual(publication.payloadSHA256, source.payloadSHA256)
        XCTAssertEqual(publication.outputRevision, source.outputRevision)
        XCTAssertEqual(publication.supersededBy, pointer)
        XCTAssertThrowsError(try queue.receive(receipt(publication, status: .stored), expected: publication))
        try queue.receive(receipt(publication, status: .superseded), expected: publication)
        XCTAssertEqual(try other.publications().count, 2, "one destination ACK cannot settle another")
        queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueueSupersession(snapshotData: data, meetingID: old.id, expectedOrdinal: 1, target: pointer)
        try queue.enqueue(acceptedData: oldBytes, record: old)
        XCTAssertTrue(try queue.publications().isEmpty, "ordinary scanning must not restore the slot")
        XCTAssertEqual(try queue.status(meetingID: old.id, outputRevision: source.outputRevision), .superseded)
        try queue.enqueueSupersession(snapshotData: data, meetingID: old.id, expectedOrdinal: 2, target: nil)
        let restored = try XCTUnwrap(queue.publications().first)
        XCTAssertEqual(restored.publicationOrdinal, 3)
        XCTAssertNil(restored.supersededBy)
        try queue.receive(receipt(restored, status: .searchable), expected: restored)
        XCTAssertThrowsError(try queue.enqueueSupersession(snapshotData: data, meetingID: old.id, expectedOrdinal: 1, target: pointer))
        XCTAssertEqual(try queue.status(meetingID: old.id, outputRevision: source.outputRevision), .searchable)
    }

    func testSupersededReceiptDoesNotStarveLaterPublication() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let old = record("old"), target = record("target"), later = record("later")
        let queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: accepted(old), record: old)
        try queue.enqueue(acceptedData: accepted(target), record: target)
        let originals = try queue.publications()
        let source = try XCTUnwrap(originals.first { $0.meetingID == old.id })
        let destination = try XCTUnwrap(originals.first { $0.meetingID == target.id })
        for item in originals { try queue.receive(receipt(item, status: .searchable), expected: item) }
        let publisher = MeetingMinutesPublisher(store: store, maxMetadataBytes: 128 * 1024)
        try await publisher.stageSupersession(snapshotData: XCTUnwrap(Data(base64Encoded: source.payloadBase64)),
            meetingID: old.id, expectedOrdinal: 1,
            target: .init(sourceUUID: queue.sourceUUID, meetingID: target.id, outputRevision: destination.outputRevision))
        _ = await publisher.accept(record: later, acceptedData: try accepted(later))
        actor Received {
            var ids: [String] = []
            func add(_ id: String) { ids.append(id) }
            func all() -> [String] { ids }
        }
        let received = Received()
        await publisher.connect { publication in
            await received.add(publication.meetingID)
            return self.receipt(publication, status: publication.supersededBy == nil ? .searchable : .superseded)
        }
        let ids = await received.all()
        XCTAssertEqual(ids, [old.id, later.id], "a settled redirect must not halt the destination drain")
        let reloaded = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        XCTAssertTrue(try reloaded.publications().isEmpty)
        XCTAssertEqual(try reloaded.status(meetingID: old.id, outputRevision: source.outputRevision), .superseded)
    }

    func testIntegrationFinalizationWaitsForBothDestinationsAndResumesWithoutDeletingSources() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let old = record("mtg-old"), target = record("mtg-target")
        let original = try accepted(old)
        for record in [old, target] {
            store.save(record)
            let bytes = record.id == old.id ? original : try accepted(record)
            try bytes.write(to: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json"))
        }
        let queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 16 * 1024 * 1024)
        try MeetingMinutesIntegrationSelection.select(targetID: target.id, otherIDs: [old.id],
            sourceUUID: queue.sourceUUID, store: store)
        XCTAssertThrowsError(try MeetingMinutesIntegrationFinalization.prepare(targetID: target.id, store: store))
        let envelope = try PetModel.minutesEnvelope(for: target, store: store, local: [], material: nil, checkingCancellation: {})
        let speech = try XCTUnwrap(envelope.segments.first { $0.source != "existing-minutes" })
        let minutes = MeetingMinutes(title: "Integrated", summary: "Grounded integration", topics: [], decisions: [],
            actionItems: [], openQuestions: [], evidence: [.init(claim: "Grounded integration", segmentIds: [speech.id])],
            attendance: nil, language: "en")
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: [envelope], completed: [minutes])
        try job.save(store: store, id: target.id)
        try store.saveValidatedMinutes(minutes, for: target, job: job)
        let plan = try MeetingMinutesIntegrationFinalization.prepare(targetID: target.id, store: store)
        XCTAssertThrowsError(try MeetingMinutesIntegrationFinalization.requireTargetReceipts(plan, store: store))
        let primary = MeetingMinutesPublisher(store: store, maxMetadataBytes: 16 * 1024 * 1024)
        await primary.connect { item in self.receipt(item, status: item.supersededBy == nil ? .searchable : .superseded) }
        actor Gate {
            var refuse = true
            func allow() { refuse = false }
            func check(_ item: MeetingMinutesPublication) throws {
                if refuse && item.supersededBy != nil { throw MeetingMinutesHubTransport.Failure.unavailable }
            }
        }
        let gate = Gate()
        let hub = MeetingMinutesHubPublisher(store: store, sender: { item in
            try await gate.check(item)
            return self.receipt(item, status: item.supersededBy == nil ? .stored : .superseded)
        })
        await hub.sync()
        do {
            try await MeetingMinutesIntegrationFinalization.finish(targetID: target.id, store: store, primary: primary, hub: hub)
            XCTFail("one destination must not hide the local source")
        } catch {}
        XCTAssertNil(store.load(id: old.id)?.mergedIntoMeetingID)
        XCTAssertEqual(try Data(contentsOf: store.directory(for: old.id).appendingPathComponent("minutes-accepted.json")), original)
        await gate.allow()
        try await MeetingMinutesIntegrationFinalization.finish(targetID: target.id, store: store, primary: primary, hub: hub)
        try await MeetingMinutesIntegrationFinalization.finish(targetID: target.id, store: store, primary: primary, hub: hub)
        XCTAssertEqual(store.load(id: old.id)?.mergedIntoMeetingID, target.id)
        for directory in ["knowledge-outbox", "knowledge-outbox-hub"] {
            let ledger = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 16 * 1024 * 1024,
                directoryName: directory, sourceUUID: queue.sourceUUID, compactsWhenStored: directory.hasSuffix("-hub"))
            let head = try XCTUnwrap(ledger.head(meetingID: old.id))
            XCTAssertEqual(head.ordinal, 2, "resume must reuse the immutable state change")
            XCTAssertEqual(head.receipt?.status, .superseded)
            XCTAssertEqual(head.supersededBy, plan.target)
        }
        XCTAssertEqual(try Data(contentsOf: store.directory(for: old.id).appendingPathComponent("minutes-accepted.json")), original)
        try Data("changed".utf8).write(to: store.directory(for: old.id).appendingPathComponent("minutes-accepted.json"))
        XCTAssertThrowsError(try MeetingMinutesIntegrationFinalization.prepare(targetID: target.id, store: store))
    }

    private func record(_ id: String = "meeting") -> MeetingRecord {
        MeetingRecord(id: id, source: "calendar", startedAt: 100, endedAt: 200,
            timeZone: "UTC", title: "Meeting", conferenceCode: nil, participants: [],
            minutesState: "ready", minutesError: nil)
    }

    private func accepted(_ record: MeetingRecord, summary: String = "Grounded summary",
                          historical: Bool = false) throws -> Data {
        let minutes = MeetingMinutes(title: "Meeting", summary: summary, topics: [], decisions: [],
            actionItems: [], openQuestions: [],
            evidence: [MeetingEvidence(claim: summary, segmentIds: ["speech-1"])],
            attendance: nil, language: "ja")
        let segment = MeetingMinutesSegment(sourceSegment: MeetingTranscriptSourceSegment(
            id: "speech-1", source: "external", text: "Unshared original speech",
            sourceURL: "https://example.invalid/source", sourceLocator: "line:1"))
        return try JSONEncoder().encode(MeetingAcceptedMinutes(minutes: minutes, fingerprint: "same-input",
            segments: [segment], unresolvedNotes: ["Incomplete coverage"], createdAt: Date(timeIntervalSince1970: 300),
            knowledgeContext: historical ? nil : .init(record: record), coverageHints: ["Selected interval only"]))
    }

    func testLegacySelectionIsExplicitAndGenerationContextIsFrozen() throws {
        let original = record()
        let legacy = try accepted(original, historical: true)
        XCTAssertThrowsError(try MeetingMinutesKnowledgeSnapshot(acceptedData: legacy, record: original)) {
            XCTAssertEqual($0 as? MeetingMinutesKnowledgeSnapshot.SnapshotError, .historicalSelectionRequired)
        }
        XCTAssertEqual(try MeetingMinutesKnowledgeSnapshot(acceptedData: legacy, record: original,
            explicitlySelected: true).contextBasis, "historical_selection_current_metadata")

        let current = try accepted(original)
        var edited = original; edited.startedAt = 500
        let snapshot = try MeetingMinutesKnowledgeSnapshot(acceptedData: current, record: edited)
        XCTAssertEqual(snapshot.context.startedAt, 100)
        XCTAssertThrowsError(try MeetingMinutesKnowledgeSnapshot(acceptedData: current, record: record("other")))
    }

    func testOutputRevisionIsNotInputFingerprintAndRawSpeechDoesNotLeaveProjection() throws {
        let r = record(), first = try accepted(r), second = try accepted(r, summary: "Revised grounded summary")
        let a = try MeetingMinutesKnowledgeSnapshot(acceptedData: first, record: r)
        let b = try MeetingMinutesKnowledgeSnapshot(acceptedData: second, record: r)
        XCTAssertEqual(a.inputFingerprint, b.inputFingerprint)
        XCTAssertNotEqual(a.outputRevision, b.outputRevision)
        XCTAssertEqual(a.outputRevision, try MeetingMinutesKnowledgeSnapshot(acceptedData: first, record: r).outputRevision)
        XCTAssertEqual(a.citations.map(\.id), ["speech-1"])
        XCTAssertEqual(a.citations.first?.sourceLocator, "line:1")
        XCTAssertEqual(a.unresolvedNotes, ["Incomplete coverage"])
        XCTAssertEqual(a.coverageHints, ["Selected interval only"])
        XCTAssertEqual(a.coverageBasis, "selected_input_only")
        let body = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertFalse(body.contains("Unshared original speech"))
    }

    func testRestartReconciliationRecoversNewDocumentButDoesNotEnrollHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let new = record("new"), old = record("old")
        for (r, legacy) in [(new, false), (old, true)] {
            let directory = store.directory(for: r.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try accepted(r, historical: legacy).write(to: directory.appendingPathComponent("minutes-accepted.json"))
        }
        let queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.reconcile(store: store, records: [new, old])
        try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
            .reconcile(store: store, records: [new, old])
        XCTAssertEqual(try queue.pending().map(\.context.meetingID), ["new"])
        let item = queue.directory.appendingPathComponent("state.json")
        try Data("corrupted binding".utf8).write(to: item)
        let originalBytes = try Data(contentsOf: store.directory(for: new.id).appendingPathComponent("minutes-accepted.json"))
        XCTAssertThrowsError(try queue.enqueue(acceptedData: originalBytes, record: new)) {
            XCTAssertEqual($0 as? AudioHubOutbox.Error, .conflict)
        }
    }

    func testCapacityPreservesPendingAndAcceptedRevisionForLaterRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root), r = record()
        let directory = store.directory(for: r.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("minutes-accepted.json")
        let first = try accepted(r)
        try first.write(to: source, options: .atomic)
        let small = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 4096)
        let queued = try small.enqueue(acceptedData: first, record: r)
        let revised = try accepted(r, summary: String(repeating: "Revised discussion ", count: 500))
        try revised.write(to: source, options: .atomic)
        XCTAssertThrowsError(try small.enqueue(acceptedData: revised, record: r)) {
            XCTAssertEqual($0 as? AudioHubOutbox.Error, .capacityExceeded)
        }
        XCTAssertEqual(try Data(contentsOf: source), revised)
        XCTAssertEqual(try small.pending().map(\.outputRevision), [queued.outputRevision])
        let restored = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try restored.reconcile(store: store, records: [r])
        XCTAssertEqual(try restored.pending().count, 2)
        XCTAssertEqual(try Data(contentsOf: source), revised)
    }
    private func receipt(_ item: MeetingMinutesPublication,
                         status: MeetingMinutesPublicationReceipt.Status,
                         current: Bool = true, hash: String? = nil) -> MeetingMinutesPublicationReceipt {
        .init(schemaVersion: 1, sourceUUID: item.sourceUUID, meetingID: item.meetingID,
              publicationOrdinal: item.publicationOrdinal, outputRevision: item.outputRevision,
              payloadSHA256: hash ?? item.payloadSHA256, status: status, isCurrent: current)
    }

    func testPublicationStoredRestartAndSearchabilityDoNotReenqueueOrArchiveBody() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = record(), bytes = try accepted(r)
        var queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: bytes, record: r)
        let item = try XCTUnwrap(queue.publications().first)
        XCTAssertEqual(item.publicationOrdinal, 1)
        XCTAssertNil(item.previousRevision)
        XCTAssertEqual(item.selectionBasis, .futureAccepted)
        XCTAssertEqual(MeetingMinutesPublication.digest(try XCTUnwrap(Data(base64Encoded: item.payloadBase64))), item.payloadSHA256)
        XCTAssertThrowsError(try queue.receive(receipt(item, status: .stored, hash: "wrong"), expected: item))
        XCTAssertEqual(try queue.publications().count, 1)
        try queue.receive(receipt(item, status: .pendingGap), expected: item)
        XCTAssertEqual(try queue.publications().count, 1)
        try queue.receive(receipt(item, status: .stored), expected: item)
        queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: bytes, record: r)
        XCTAssertTrue(try queue.publications().isEmpty)
        XCTAssertEqual(try queue.awaitingSearchability(), [item])
        try queue.receive(receipt(item, status: .searchable), expected: item)
        try queue.receive(receipt(item, status: .stored), expected: item) // delayed reply cannot regress
        XCTAssertTrue(try queue.awaitingSearchability().isEmpty)
        queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: bytes, record: r)
        XCTAssertTrue(try queue.publications().isEmpty)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            queue.directory.appendingPathComponent("state.json"))) as? [String: Any])
        let entries = try XCTUnwrap(state["entries"] as? [[String: Any]])
        XCTAssertNil(entries.first?["payload"])
    }

    func testPublicationRevisionOrderingSelectionAndExactEnvelopeReceipt() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = record(), first = try accepted(r), second = try accepted(r, summary: "Revised")
        let queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: first, record: r)
        try queue.enqueue(acceptedData: second, record: r, explicitlySelected: true)
        try queue.enqueue(acceptedData: first, record: r) // old revision does not allocate a new ordinal
        let items = try queue.publications()
        XCTAssertEqual(items.map(\.publicationOrdinal), [1, 2])
        XCTAssertEqual(items[1].previousRevision, items[0].outputRevision)
        XCTAssertEqual(items[1].selectionBasis, .explicitHistory)
        let changed = MeetingMinutesPublication(schemaVersion: 1, operation: .delete,
            sourceUUID: items[1].sourceUUID, meetingID: r.id, outputRevision: items[1].outputRevision,
            publicationOrdinal: 2, previousRevision: items[0].outputRevision,
            selectionBasis: .explicitHistory, payloadSHA256: items[1].payloadSHA256, payloadBase64: items[1].payloadBase64)
        XCTAssertThrowsError(try queue.receive(receipt(items[1], status: .stored), expected: changed))
        try queue.receive(receipt(items[1], status: .stored), expected: items[1])
        try queue.receive(receipt(items[0], status: .stored, current: false), expected: items[0])
        XCTAssertEqual(try queue.awaitingSearchability(), [items[1]])
        XCTAssertTrue(try queue.publications().isEmpty)
    }

    func testPublicationExplicitDeletionCannotBeResurrectedByOldAcceptedFile() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = record(), bytes = try accepted(r)
        var queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try queue.enqueue(acceptedData: bytes, record: r)
        let upsert = try XCTUnwrap(queue.publications().first)
        try queue.receive(receipt(upsert, status: .searchable), expected: upsert)
        try queue.enqueueDeletion(meetingID: r.id, expectedRevision: upsert.outputRevision)
        let deletion = try XCTUnwrap(queue.publications().first)
        XCTAssertEqual(deletion.operation, .delete)
        XCTAssertEqual(deletion.publicationOrdinal, 2)
        XCTAssertEqual(deletion.payloadSHA256, MeetingMinutesPublication.digest(Data()))
        XCTAssertEqual(deletion.payloadBase64, "")
        XCTAssertThrowsError(try queue.receive(receipt(deletion, status: .stored), expected: deletion))
        try queue.receive(receipt(deletion, status: .deleted), expected: deletion)
        queue = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        XCTAssertThrowsError(try queue.enqueue(acceptedData: bytes, record: r))
        XCTAssertThrowsError(try queue.enqueue(acceptedData: accepted(r, summary: "New revision after deletion"), record: r))
        try queue.enqueueDeletion(meetingID: r.id, expectedRevision: upsert.outputRevision)
        XCTAssertTrue(try queue.publications().isEmpty)
    }

    private actor PublicationSink {
        var fail = true
        var sent: [MeetingMinutesPublication] = []
        func setReady() { fail = false }
        func items() -> [MeetingMinutesPublication] { sent }
        func send(_ item: MeetingMinutesPublication) throws -> MeetingMinutesPublicationReceipt {
            sent.append(item)
            if fail { throw OpenClawError.timeout }
            return .init(schemaVersion: 1, sourceUUID: item.sourceUUID, meetingID: item.meetingID,
                publicationOrdinal: item.publicationOrdinal, outputRevision: item.outputRevision,
                payloadSHA256: item.payloadSHA256, status: item.operation == .delete ? .deleted : .searchable,
                isCurrent: true)
        }
    }

    func testPublisherOfflineReconnectExactRetryAndLegacyExclusion() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = record("mtg-new"), legacy = record("mtg-legacy")
        let bytes = try accepted(r)
        for (item, data) in [(r, bytes), (legacy, try accepted(legacy, historical: true))] {
            store.save(item)
            try data.write(to: store.directory(for: item.id).appendingPathComponent("minutes-accepted.json"))
        }
        let publisher = MeetingMinutesPublisher(store: store, maxMetadataBytes: 128 * 1024)
        await publisher.accept(record: r, acceptedData: bytes)
        XCTAssertEqual(try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024).pending().count, 1)
        let sink = PublicationSink()
        await publisher.connect { try await sink.send($0) }
        XCTAssertEqual(try Data(contentsOf: store.directory(for: r.id).appendingPathComponent("minutes-accepted.json")), bytes)
        XCTAssertEqual(try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024).publications().count, 1)
        await sink.setReady()
        await publisher.connect { try await sink.send($0) }
        var sent = await sink.items()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1]) // uncertain outcome retried with exact immutable identity
        XCTAssertEqual(sent[0].meetingID, r.id)
        XCTAssertTrue(try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024).publications().isEmpty)
        await publisher.connect { try await sink.send($0) }
        sent = await sink.items()
        XCTAssertEqual(sent.count, 2) // settled reconciliation neither resends nor enrolls legacy
        let revised = try accepted(r, summary: "Revised accepted statement")
        try revised.write(to: store.directory(for: r.id).appendingPathComponent("minutes-accepted.json"))
        await publisher.accept(record: r, acceptedData: revised)
        sent = await sink.items()
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[2].publicationOrdinal, 2)
        XCTAssertEqual(sent[2].previousRevision, sent[0].outputRevision)
        let ledger = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        try ledger.enqueueDeletion(meetingID: r.id, expectedRevision: sent[2].outputRevision)
        await publisher.connect { try await sink.send($0) }
        await publisher.connect { try await sink.send($0) }
        sent = await sink.items()
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(sent[3].operation, .delete)
    }

    func testExplicitSelectionRejectsChangedAcceptedVersionAndReceiptStatesStayDistinct() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = record("mtg-selected")
        store.save(r)
        let bytes = try accepted(r, historical: true)
        let url = store.directory(for: r.id).appendingPathComponent("minutes-accepted.json")
        try bytes.write(to: url)
        let revision = "sha256:" + MeetingMinutesPublication.digest(bytes)
        let selection = try MeetingMinutesKnowledgeSelection(store: store, record: r, expectedRevision: revision)
        XCTAssertTrue(selection.historical)
        let ledger = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 128 * 1024)
        XCTAssertEqual(try ledger.status(meetingID: r.id, outputRevision: revision), .notStaged)
        try ledger.enqueue(acceptedData: selection.data, record: r, explicitlySelected: selection.historical)
        let item = try XCTUnwrap(ledger.publications().first)
        XCTAssertEqual(item.selectionBasis, .explicitHistory)
        XCTAssertEqual(try ledger.status(meetingID: r.id, outputRevision: revision), .pending)
        try ledger.receive(receipt(item, status: .stored), expected: item)
        XCTAssertEqual(try ledger.status(meetingID: r.id, outputRevision: revision), .stored)
        try ledger.receive(receipt(item, status: .searchable), expected: item)
        XCTAssertEqual(try ledger.status(meetingID: r.id, outputRevision: revision), .searchable)
        try accepted(r, summary: "Replacement not selected", historical: true).write(to: url)
        XCTAssertThrowsError(try MeetingMinutesKnowledgeSelection(store: store, record: r, expectedRevision: revision))
        try ledger.enqueueDeletion(meetingID: r.id, expectedRevision: revision)
        XCTAssertEqual(try ledger.status(meetingID: r.id, outputRevision: revision), .deletionPending)
        let deletion = try XCTUnwrap(ledger.publications().first)
        try ledger.receive(receipt(deletion, status: .deleted), expected: deletion)
        XCTAssertEqual(try ledger.status(meetingID: r.id, outputRevision: revision), .deleted)
    }

}
