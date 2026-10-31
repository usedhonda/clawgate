import XCTest
@testable import ClawGate

final class MeetingMinutesHubPublisherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func record(_ id: String) -> MeetingRecord {
        MeetingRecord(id: id, source: "meet", startedAt: 1_000, endedAt: 2_000, timeZone: "UTC",
                      title: id, conferenceCode: nil, participants: [], minutesState: "ready", minutesError: nil)
    }

    private func export(_ summary: String) throws -> Data {
        try JSONEncoder().encode(MeetingMinutes(title: nil, summary: summary, topics: [], decisions: [], actionItems: [], openQuestions: [], evidence: nil, attendance: nil, language: nil))
    }

    private func receipt(_ publication: MeetingMinutesPublication) -> MeetingMinutesPublicationReceipt {
        MeetingMinutesPublicationReceipt(schemaVersion: 1, sourceUUID: publication.sourceUUID,
            meetingID: publication.meetingID, publicationOrdinal: publication.publicationOrdinal,
            outputRevision: publication.outputRevision, payloadSHA256: publication.payloadSHA256,
            status: .stored, isCurrent: true)
    }

    /// An older document without an accepted file is shown by the app, so the Hub
    /// gets it too; a stored receipt ends delivery and the body leaves the ledger.
    func testExportOnlyMinutesAreDeliveredOnceUnderTheInstallationSource() async throws {
        let store = MeetingStore(root: root)
        let meeting = record("mtg-legacy")
        store.save(meeting)
        let directory = store.directory(for: meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try export("same").write(to: directory.appendingPathComponent("minutes.json"))

        final class Box: @unchecked Sendable { var sent: [MeetingMinutesPublication] = [] }
        let box = Box()
        let tests = self
        let publisher = MeetingMinutesHubPublisher(store: store) { publication in
            box.sent.append(publication)
            return tests.receipt(publication)
        }
        await publisher.sync()
        await publisher.sync()

        XCTAssertEqual(box.sent.count, 1)
        let sent = try XCTUnwrap(box.sent.first)
        XCTAssertEqual(sent.selectionBasis, .explicitHistory)
        let primary = try MeetingMinutesKnowledgeOutbox(store: store, maxMetadataBytes: 1 << 20)
        XCTAssertEqual(sent.sourceUUID, primary.sourceUUID)
        XCTAssertTrue(try primary.publications().isEmpty, "the Gateway route must not gain this document")
        let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: sent.payloadBase64))) as? [String: Any]
        XCTAssertEqual(payload?["contextBasis"] as? String, "historical_selection_current_metadata")
        XCTAssertEqual((payload?["minutes"] as? [String: Any])?["summary"] as? String, "same")
        let hubState = try Data(contentsOf: root.appendingPathComponent("knowledge-outbox-hub/state.json"))
        XCTAssertFalse(String(decoding: hubState, as: UTF8.self).contains(sent.payloadBase64))
    }

    func testReceiptMustEchoTheExactPublication() throws {
        let publication = MeetingMinutesPublication(schemaVersion: 1, operation: .upsert, sourceUUID: "s", meetingID: "m",
            outputRevision: "sha256:r", publicationOrdinal: 1, previousRevision: nil, selectionBasis: .futureAccepted,
            payloadSHA256: "h", payloadBase64: "")
        func body(ordinal: Int) -> Data {
            try! JSONSerialization.data(withJSONObject: ["status": "created", "minutes_receipt": [
                "schemaVersion": 1, "sourceUUID": "s", "meetingID": "m", "publicationOrdinal": ordinal,
                "outputRevision": "sha256:r", "payloadSHA256": "h", "status": "stored", "isCurrent": true,
                "historyGap": false, "eventId": "e"]])
        }
        XCTAssertEqual(try MeetingMinutesHubTransport.receipt(from: body(ordinal: 1), matching: publication).status, .stored)
        XCTAssertThrowsError(try MeetingMinutesHubTransport.receipt(from: body(ordinal: 2), matching: publication))
    }

    /// The Hub adding a domain for this source must not stop existing audio delivery.
    func testCapabilitiesAcceptGrantedSupersetAndRequireMinutesWhenAsked() throws {
        let provision = try HubProducerProvision.parse(Data("""
        {"schema_version":1,"source":"clawgate","base_url":"https://hub.example.invalid","bearer_token":"t","allowed_domains":["audio"]}
        """.utf8), source: "clawgate")
        func capabilities(_ domains: [String]) -> Data {
            try! JSONSerialization.data(withJSONObject: ["version": 1, "source": "clawgate", "domains": domains,
                "storage_receipt_version": 1, "max_event_bytes": 20 * 1024 * 1024,
                "max_chunk_bytes": 4 * 1024 * 1024, "finalize_replay_safe": true])
        }
        XCTAssertTrue(provision.acceptsCapabilities(capabilities(["audio", "minutes"])))
        XCTAssertTrue(provision.acceptsCapabilities(capabilities(["audio", "minutes"]), requiring: "minutes"))
        XCTAssertFalse(provision.acceptsCapabilities(capabilities(["audio"]), requiring: "minutes"))
        XCTAssertFalse(provision.acceptsCapabilities(capabilities(["minutes"])))
    }
}
