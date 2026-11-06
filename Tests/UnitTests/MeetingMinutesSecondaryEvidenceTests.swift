import XCTest
@testable import ClawGate

final class MeetingMinutesSecondaryEvidenceTests: XCTestCase {
    func testGroundedReplyGetsDeterministicLabelsWithoutLosingReconciliationMappings() throws {
        let record = MeetingRecord(id: "mtg-fixture", source: "manual", startedAt: 100, endedAt: 200,
            timeZone: "UTC", title: nil, conferenceCode: nil, participants: [], minutesState: "pending", minutesError: nil)
        let envelope = MeetingMinutesEnvelope.build(record: record, sourceSegments: [
            .init(id: "note", source: "existing-minutes", text: "初めの事項です。両方の資料に記載があります。"),
            .init(id: "speech", source: "local", text: "次の事項です。両方の資料に記載があります。")
        ])
        let first = "初めの事項です。", second = "次の事項です。", mixed = "両方の資料に記載があります。"
        let raw = MeetingMinutes(title: "Fixture", summary: first + "\n" + second,
            topics: [.init(heading: "Topic", points: [mixed])], decisions: [first],
            actionItems: [.init(what: first, owner: "Owner", due: "Later", mine: false)], openQuestions: [mixed],
            evidence: [.init(claim: first, segmentIds: ["note"]), .init(claim: second, segmentIds: ["speech"]),
                       .init(claim: mixed, segmentIds: ["note", "speech"])], attendance: nil, language: "ja")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(raw))
        let wrapper: [String: Any] = ["outcome": "answer", "minutes": object,
            "contextDecision": ["policyVersion": MeetingMinutesPrompt.policyVersion]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: wrapper), as: UTF8.self)
        let parsed = try XCTUnwrap(MeetingMinutesParser.parse(text, validSegmentIds: ["note", "speech"]))
        XCTAssertThrowsError(try MeetingMinutesSecondaryEvidence.validate(parsed, segments: envelope.segments))
        let marked = MeetingMinutesSecondaryEvidence.annotate(parsed, segments: envelope.segments).minutes
        let label = MeetingMinutesSecondaryEvidence.label
        XCTAssertEqual(marked.summary, label + first + "\n" + second)
        XCTAssertEqual(marked.topics[0].points, [label + mixed])
        XCTAssertEqual(marked.decisions, [label + first])
        XCTAssertEqual(marked.actionItems[0], .init(what: label + first, owner: "Owner", due: "Later", mine: false))
        XCTAssertEqual(marked.openQuestions, [label + mixed])
        XCTAssertEqual(marked.evidence?.map(\.segmentIds), parsed.evidence?.map(\.segmentIds))
        XCTAssertNoThrow(try MeetingMinutesSecondaryEvidence.validate(marked, segments: envelope.segments))
        XCTAssertEqual(MeetingMinutesSecondaryEvidence.annotate(marked, segments: envelope.segments).minutes, marked)
        XCTAssertThrowsError(try MeetingMinutesParser.parse(text, validSegmentIds: ["speech"]))

        let input = MeetingMinutesSummaryPass.input(for: raw, parts: [raw], record: record, segments: envelope.segments)
        let reply = MeetingMinutesSummaryPass.Reply(policyVersion: MeetingMinutesSummaryPass.policyVersion,
            minutes: raw, resolutions: input.claims.map {
                .init(sourceClaimIds: [$0.id], disposition: "retained", outputClaims: [$0.text], quotes: [])
            })
        let reconciled = try MeetingMinutesSummaryPass.parse(
            String(decoding: JSONEncoder().encode(reply), as: UTF8.self), input: input)
        XCTAssertEqual(reconciled.minutes, marked)
        XCTAssertEqual(Set(reconciled.resolutions.flatMap(\.sourceClaimIds)), Set(input.claims.map(\.id)))
        XCTAssertEqual(Set(reconciled.resolutions.flatMap(\.outputClaims)), [label + first, second, label + mixed])
    }

    func testLongNotePreservesTextAndDocumentIdentityWithoutInventingAudio() {
        let text = String(repeating: "会議🙂", count: 4_001)
        let note = MeetingGoogleMaterials.GeneratedNote(id: "note", sourceURL: "https://example.com/document",
            locator: "tab:1", text: text)
        let segments = MeetingMinutesSecondaryEvidence.segments([note])
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.map(\.text).joined(), text)
        XCTAssertEqual(Set(segments.map(\.id)).count, segments.count)
        XCTAssertTrue(segments.allSatisfy { $0.text.count <= 6_000 && $0.capturedAt == nil && $0.recallLineage == nil })
        XCTAssertTrue(segments.allSatisfy { $0.source == "existing-minutes" && $0.sourceLocator?.contains("sha256:") == true })
        XCTAssertEqual(MeetingMinutesSecondaryEvidence.segments([note]), segments)
    }

    func testSelectedMeetingRevisionsPreserveSourcesWithoutAudioReplay() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let records = ["mtg-target", "mtg-other", "mtg-legacy"].map { id in
            MeetingRecord(id: id, source: "manual", startedAt: 100, endedAt: 200, timeZone: "UTC",
                title: "Fixture", conferenceCode: nil, participants: [], minutesState: "ready", minutesError: nil)
        }
        var originals: [Data] = []
        for (index, record) in records.enumerated() {
            store.save(record)
            let text = index == 0 ? "Budget is 10 million" : "Budget is 20 million"
            let minutes = MeetingMinutes(title: "Fixture", summary: text, topics: [], decisions: [text],
                actionItems: [], openQuestions: [], evidence: [.init(claim: text, segmentIds: ["seg-1"])],
                attendance: nil, language: nil)
            if index < 2 {
                let segment = MeetingTranscriptSourceSegment(id: "seg-1", source: index == 0 ? "local" : "meet",
                    text: text, speaker: "Speaker", capturedAt: 120, sourceLocator: "original:1", startSeconds: 20, endSeconds: 21)
                let envelope = MeetingMinutesEnvelope.build(record: record, sourceSegments: [segment])
                let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: [envelope], completed: [minutes])
                try store.saveValidatedMinutes(minutes, for: record, job: job)
                originals.append(try Data(contentsOf: store.directory(for: record.id).appendingPathComponent("minutes-accepted.json")))
            } else {
                try JSONEncoder().encode(minutes).write(to: store.directory(for: record.id).appendingPathComponent("minutes.json"))
            }
        }
        let uuid = UUID().uuidString.lowercased()
        try MeetingMinutesIntegrationSelection.select(targetID: "mtg-target", otherIDs: ["mtg-other", "mtg-legacy"], sourceUUID: uuid, store: store)
        let selection = try XCTUnwrap(MeetingMinutesIntegrationSelection.load(targetID: "mtg-target", store: store))
        XCTAssertEqual(selection.sources.map(\.authority), ["accepted", "accepted", "legacy-export"])
        for index in 0..<2 {
            XCTAssertEqual(try Data(contentsOf: store.directory(for: records[index].id).appendingPathComponent("minutes-accepted.json")), originals[index])
            XCTAssertEqual(selection.sources[index].bytes, originals[index])
        }
        let segments = try selection.segments()
        let speech = segments.filter { $0.source != "existing-minutes" }
        XCTAssertEqual(Set(segments.map(\.id)).count, segments.count, "same source IDs must not collide across meetings")
        XCTAssertEqual(speech.map(\.text), ["Budget is 10 million", "Budget is 20 million"])
        XCTAssertTrue(speech.allSatisfy { $0.capturedAt == 120 && $0.startSeconds == 20 && $0.endSeconds == 21 && $0.speaker == "Speaker" })
        XCTAssertTrue(speech.allSatisfy { $0.sourceLocator?.contains("original:1") == true })
        let notes = segments.filter { $0.source == "existing-minutes" }
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes.allSatisfy { $0.capturedAt == nil && $0.recallLineage == nil })
        XCTAssertTrue(notes.contains { $0.sourceLocator?.contains("legacy-export") == true })
        // Later source damage must not retarget or destroy the pinned snapshot.
        try Data("changed".utf8).write(to: store.directory(for: "mtg-other").appendingPathComponent("minutes-accepted.json"))
        XCTAssertEqual(try MeetingMinutesIntegrationSelection.load(targetID: "mtg-target", store: store)?.segments(), segments)
        let envelope = try PetModel.minutesEnvelope(for: records[0], store: store, local: [], material: nil, checkingCancellation: {})
        XCTAssertNotNil(envelope.integrationSelectionFingerprint)
        XCTAssertFalse(envelope.unresolvedNotes?.isEmpty ?? true)
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope),
            envelopes: MeetingMinutes.chunked(envelope, maxCharacters: 100), completed: [])
        XCTAssertEqual(job.frozenEnvelope?.integrationSelectionFingerprint, envelope.integrationSelectionFingerprint)
        try job.save(store: store, id: "mtg-target")
        var pending = records[0]; pending.minutesState = "pending"; store.save(pending)
        let drain = try XCTUnwrap(MeetingMinutesDrainSnapshot.load(store: store, sessionsRoot: store.root.appendingPathComponent("sessions"),
            transcript: nil, materials: [:], notBefore: [:], preparing: [], now: Date(), ticket: .init(requestedAt: nil)))
        XCTAssertFalse(drain.needsReview, "selected historical inputs are not authorization for new ASR")
        let manifest = store.directory(for: "mtg-target").appendingPathComponent(MeetingMinutesIntegrationSelection.fileName)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var entries = try XCTUnwrap(object["sources"] as? [[String: Any]])
        entries[0]["revision"] = "wrong"; object["sources"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        XCTAssertThrowsError(try MeetingMinutesIntegrationSelection.load(targetID: "mtg-target", store: store))
        XCTAssertThrowsError(try PetModel.minutesEnvelope(for: records[0], store: store, local: [], material: nil, checkingCancellation: {}))
        XCTAssertEqual(try Data(contentsOf: store.directory(for: "mtg-target").appendingPathComponent("minutes-accepted.json")), originals[0])
    }

    func testUnlabelledSecondaryClaimCannotReplaceAcceptedDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let record = MeetingRecord(id: "meeting", source: "manual", startedAt: 100, endedAt: 200,
            timeZone: "UTC", title: nil, conferenceCode: nil, participants: [], minutesState: "ready", minutesError: nil)
        let source = MeetingMinutesSecondaryEvidence.segments([
            .init(id: "note", sourceURL: "https://example.com/document", locator: nil, text: "予算は100です")
        ])
        let envelope = MeetingMinutesEnvelope.build(record: record, sourceSegments: source)
        func minutes(_ label: Bool) -> MeetingMinutes {
            let claim = (label ? MeetingMinutesSecondaryEvidence.label : "") + "予算は100です"
            return MeetingMinutes(title: nil, summary: claim, topics: [], decisions: [claim],
                actionItems: [.init(what: claim, owner: nil, due: nil, mine: nil)], openQuestions: [],
                evidence: [.init(claim: claim, segmentIds: [source[0].id])], attendance: nil, language: "ja")
        }
        let good = minutes(true)
        let job = MeetingMinutesJob(fingerprint: MeetingMinutesJob.fingerprint(envelope), envelopes: [envelope], completed: [good])
        try store.saveValidatedMinutes(good, for: record, job: job)
        let path = store.directory(for: record.id).appendingPathComponent("minutes-accepted.json")
        let before = try Data(contentsOf: path)
        XCTAssertThrowsError(try store.saveValidatedMinutes(minutes(false), for: record, job: job))
        XCTAssertEqual(try Data(contentsOf: path), before)
        let snapshot = try MeetingMinutesKnowledgeSnapshot(acceptedData: before, record: record)
        XCTAssertEqual(snapshot.citations.first?.source, "existing-minutes")
        XCTAssertTrue(snapshot.minutes.actionItems[0].what.hasPrefix(MeetingMinutesSecondaryEvidence.label))
    }
}
