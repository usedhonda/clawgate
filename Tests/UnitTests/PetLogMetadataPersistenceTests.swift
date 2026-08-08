import XCTest
@testable import ClawGate

/// D7: correlation metadata persistence. The 2026-08 incident's forensics were
/// unrecoverable because the real sent segment count and scope were never
/// written down. These guards assert that both the request-side (`log_user`)
/// entry and its structured answer carry the exact envelope's correlation
/// fields, and that they survive a Codable round-trip.
final class PetLogMetadataPersistenceTests: XCTestCase {
    private var originalDir = ""

    override func setUp() {
        super.setUp()
        PetLogStore.testIsolationSemaphore.wait()
        originalDir = PetLogStore.dir
        PetLogStore.dir = NSTemporaryDirectory() + "clawgate-test-logs-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: PetLogStore.dir, withIntermediateDirectories: true)
        PetLogStore.resetPoisonedForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: PetLogStore.dir)
        PetLogStore.resetPoisonedForTesting()
        PetLogStore.dir = originalDir
        PetLogStore.testIsolationSemaphore.signal()
        super.tearDown()
    }

    private static let explicitSegmentIds = ["s0"]

    private func explicitEnvelope(requestId: String) -> PetLogQueryEnvelope {
        PetLogQueryEnvelope(
            requestId: requestId, actionId: "slot-2", instruction: "質問まとめ",
            queryTimestamp: Date(timeIntervalSince1970: 1_700_000_500),
            anchorTimestamp: Date(timeIntervalSince1970: 1_700_000_400),
            scopeOverride: ["scene-1785822940"],
            coverageStart: nil, coverageEnd: nil,
            completeBeforeAnchor: true,
            segments: Self.explicitSegmentIds.map {
                PetLogRawSegment(id: $0, capturedAt: nil, startSeconds: 0, endSeconds: 1, speaker: nil, text: "x")
            }
        )
    }

    func testUserEntryCarriesEnvelopeCorrelationMetadata() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let requestId = UUID().uuidString
        let selectedDay = Date(timeIntervalSince1970: 1_699_920_000)
        model.sendLogInstruction(envelope: explicitEnvelope(requestId: requestId), selectedDay: selectedDay)

        guard let userEntry = model.logReplies.first(where: { $0.source == "log_user" }) else {
            return XCTFail("a log_user entry must be persisted")
        }
        guard let meta = userEntry.logMetadata else {
            return XCTFail("the log_user entry must carry correlation metadata")
        }
        XCTAssertEqual(meta.requestId, requestId)
        XCTAssertEqual(meta.actionId, "slot-2")
        XCTAssertEqual(meta.segmentCount, 1)
        XCTAssertEqual(meta.scopeOverride, ["scene-1785822940"])
        XCTAssertEqual(meta.selectionMode, "explicit")
        XCTAssertEqual(meta.selectedDay, selectedDay)
        XCTAssertEqual(meta.anchor, Date(timeIntervalSince1970: 1_700_000_400))
        // A request-side entry has no model verdict, but DOES carry the client's
        // completeness signal so it stands as sole evidence if no answer arrives.
        XCTAssertNil(meta.contextDecision)
        XCTAssertEqual(meta.completeBeforeAnchor, true)
        XCTAssertEqual(meta.policyVersion, PetLogPromptBuilder.policyVersion)
        XCTAssertEqual(meta.sourceFingerprint,
                       PetLogSourceFingerprint.make(policyVersion: PetLogPromptBuilder.policyVersion, segmentIds: Self.explicitSegmentIds))
        XCTAssertFalse(meta.isUncertain, "a complete request-side entry is not 'uncertain'")
    }

    func testStructuredReplyPairsCorrelationWithModelVerdict() {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let requestId = UUID().uuidString
        let selectedDay = Date(timeIntervalSince1970: 1_699_920_000)
        model.sendLogInstruction(envelope: explicitEnvelope(requestId: requestId), selectedDay: selectedDay)

        // Deliver a well-formed structured reply that includes the sent segment
        // exactly (explicit scope requires exact-all inclusion).
        let reply = fullInclusionReplyJSON(answer: "本文", ids: Self.explicitSegmentIds)
        model.addSummonResult(text: reply, source: "log", parseAsStructured: true)

        guard let answerEntry = model.logReplies.last(where: { $0.source == "log" }) else {
            return XCTFail("a structured answer entry must be persisted")
        }
        XCTAssertEqual(answerEntry.text, "本文")
        guard let meta = answerEntry.logMetadata else {
            return XCTFail("the answer entry must carry metadata")
        }
        // Correlation pairs the answer back to the same request as the prompt.
        XCTAssertEqual(meta.requestId, requestId)
        XCTAssertEqual(meta.actionId, "slot-2")
        XCTAssertEqual(meta.segmentCount, 1)
        XCTAssertEqual(meta.scopeOverride, ["scene-1785822940"])
        XCTAssertEqual(meta.selectionMode, "explicit")
        XCTAssertEqual(meta.selectedDay, selectedDay)
        // ...alongside the model's own verdict + the client's completeness signal.
        XCTAssertNotNil(meta.contextDecision)
        XCTAssertEqual(meta.completeBeforeAnchor, true)
    }

    /// The new correlation fields must survive the exact encoder/decoder the
    /// store uses (iso8601 dates), and pre-D7 records (no correlation keys) must
    /// still decode with those fields nil.
    func testCorrelationMetadataCodableRoundTripAndBackwardCompat() throws {
        let meta = PetLogEntryMetadata(
            requestId: "req-1", actionId: "slot-0",
            anchor: Date(timeIntervalSince1970: 1_700_000_400),
            selectedDay: Date(timeIntervalSince1970: 1_699_920_000),
            segmentCount: 700, scopeOverride: ["a", "b"], selectionMode: "automatic"
        )
        let entry = NotificationEntry(
            id: "e", text: "x", source: "log_user",
            timestamp: Date(timeIntervalSince1970: 1_700_000_500), logMetadata: meta
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NotificationEntry.self, from: encoder.encode(entry))
        XCTAssertEqual(decoded.logMetadata, meta)
        XCTAssertEqual(decoded.logMetadata?.segmentCount, 700)
        XCTAssertEqual(decoded.logMetadata?.scopeOverride, ["a", "b"])

        // A pre-D7 metadata record: contextDecision + completeBeforeAnchor only.
        let legacyJSON = """
        {"id":"o","text":"a","source":"log","timestamp":"2026-08-09T00:00:00Z",
         "logMetadata":{"contextDecision":{"policyVersion":"\(PetLogPromptBuilder.policyVersion)",
         "includedSegmentIds":[],"includedRange":null,"excludedAdjacentRange":null,
         "boundaryReasonCodes":[],"boundaryConfidence":"high","historyComplete":true,
         "correctionCounts":{}},"completeBeforeAnchor":true}}
        """
        let legacy = try decoder.decode(NotificationEntry.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.logMetadata?.requestId, "pre-D7 records decode with correlation fields nil")
        XCTAssertEqual(legacy.logMetadata?.completeBeforeAnchor, true)
        XCTAssertNotNil(legacy.logMetadata?.contextDecision)
    }

    // MARK: - Incident-scale round-trip (D7 gap 4)

    /// Builds an N-segment envelope mirroring the incident scale (hundreds of
    /// pre-anchor segments). `explicit` sets a scope override.
    private func largeEnvelope(requestId: String, count: Int, explicit: Bool) -> PetLogQueryEnvelope {
        let base = 1_700_000_000.0
        let segments = (0..<count).map { i in
            PetLogRawSegment(
                id: "seg-\(i)", capturedAt: base + Double(i),
                startSeconds: 0, endSeconds: 1, speaker: i % 2 == 0 ? "A" : "B",
                text: "utterance \(i)")
        }
        return PetLogQueryEnvelope(
            requestId: requestId, actionId: "slot-1", instruction: "TODO抽出",
            queryTimestamp: Date(timeIntervalSince1970: base + Double(count) + 10),
            anchorTimestamp: Date(timeIntervalSince1970: base + Double(count) + 5),
            scopeOverride: explicit ? ["scene-1785822940"] : nil,
            coverageStart: Date(timeIntervalSince1970: base),
            coverageEnd: Date(timeIntervalSince1970: base + Double(count - 1)),
            completeBeforeAnchor: true, segments: segments)
    }

    /// A structured reply that includes ALL sent ids in order (the honest
    /// full-retention answer). range endpoints = first/last.
    private func fullInclusionReplyJSON(answer: String, ids: [String]) -> String {
        let escaped = String(data: try! JSONEncoder().encode(answer), encoding: .utf8)!
        let idList = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {
          "answer": \(escaped),
          "contextDecision": {
            "policyVersion": "\(PetLogPromptBuilder.policyVersion)",
            "includedSegmentIds": [\(idList)],
            "includedRange": {"startSegmentId": "\(ids.first!)", "endSegmentId": "\(ids.last!)"},
            "excludedAdjacentRange": null,
            "boundaryReasonCodes": [],
            "boundaryConfidence": "high",
            "historyComplete": true,
            "correctionCounts": {}
          }
        }
        """
    }

    private func runLargeRoundTrip(explicit: Bool) {
        let model = PetModel()
        model.connectionState = .connected
        model.setSessionKeyForTesting("test-session")
        model.suppressLogSendForTesting = true

        let requestId = UUID().uuidString
        let selectedDay = Date(timeIntervalSince1970: 1_699_920_000)
        let envelope = largeEnvelope(requestId: requestId, count: 312, explicit: explicit)
        let ids = envelope.segments.map(\.id)
        let expectedFingerprint = PetLogSourceFingerprint.make(
            policyVersion: PetLogPromptBuilder.policyVersion, segmentIds: ids)

        model.sendLogInstruction(envelope: envelope, selectedDay: selectedDay)
        model.addSummonResult(text: fullInclusionReplyJSON(answer: "まとめ", ids: ids),
                              source: "log", parseAsStructured: true)

        guard let user = model.logReplies.first(where: { $0.source == "log_user" })?.logMetadata,
              let answer = model.logReplies.last(where: { $0.source == "log" })?.logMetadata else {
            return XCTFail("both a log_user and a log answer entry must be persisted")
        }
        let mode = explicit ? "explicit" : "automatic"
        for (label, m) in [("user", user), ("answer", answer)] {
            XCTAssertEqual(m.requestId, requestId, "\(label) requestId")
            XCTAssertEqual(m.segmentCount, 312, "\(label) segmentCount")
            XCTAssertEqual(m.selectionMode, mode, "\(label) selectionMode")
            XCTAssertEqual(m.coverageStart, envelope.coverageStart, "\(label) coverageStart")
            XCTAssertEqual(m.coverageEnd, envelope.coverageEnd, "\(label) coverageEnd")
            XCTAssertEqual(m.policyVersion, PetLogPromptBuilder.policyVersion, "\(label) policyVersion")
            XCTAssertEqual(m.sourceFingerprint, expectedFingerprint, "\(label) fingerprint")
            XCTAssertEqual(m.completeBeforeAnchor, true, "\(label) completeness")
            XCTAssertEqual(m.scopeOverride, explicit ? ["scene-1785822940"] : nil, "\(label) scopeOverride")
        }
        // The answer additionally carries the model verdict; both pair by id.
        XCTAssertNotNil(answer.contextDecision)
        XCTAssertEqual(user.requestId, answer.requestId, "request and answer must share the requestId")
    }

    func testAutomaticLargeQueryRoundTripsCorrelation() { runLargeRoundTrip(explicit: false) }
    func testExplicitLargeQueryRoundTripsCorrelation() { runLargeRoundTrip(explicit: true) }
}
