import XCTest
@testable import ClawGate

/// Live integration test for ambient.ingest L2 events against a real Gateway.
/// Disabled by default — run explicitly with:
///   AMBIENT_LIVE_TEST=1 AMBIENT_LIVE_URL="ws://<gateway-host>:18789/" \
///     swift test --filter AmbientLiveIngestTests
/// Uses the production code path (extractor → params → OpenClawWSClient) and
/// prints per-event receipts for cross-checking against the Gateway's JSONL.
final class AmbientLiveIngestTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeEvent(_ d: AmbientSalientExtractor.Draft,
                           seq: Int,
                           runID: String,
                           sw: AmbientSourceWindow,
                           privacyFlags: [String] = []) -> AmbientSalientEvent {
        AmbientSalientEvent(
            source: "clawgate_ambient",
            sourceSeq: seq,
            sourceEventId: "\(runID)-ev\(seq)",
            eventType: d.eventType,
            normalizedSubject: d.normalizedSubject,
            normalizedDateBucket: d.normalizedDateBucket,
            dedupKey: d.dedupKey,
            summary: d.summary,
            confidence: d.confidence,
            sourceWindow: sw,
            privacyFlags: privacyFlags
        )
    }

    private func receiptLine(_ r: AmbientEventReceipt) -> String {
        "sourceEventId=\(r.sourceEventId ?? "?") eventId=\(r.eventId ?? "?") status=\(r.status ?? "?") dedup=\(r.dedup ?? "?")"
    }

    func testLiveIngestEventsAgainstGateway() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["AMBIENT_LIVE_TEST"] == "1", "live test disabled (set AMBIENT_LIVE_TEST=1)")
        let urlString = try XCTUnwrap(env["AMBIENT_LIVE_URL"], "AMBIENT_LIVE_URL required")
        let url = try XCTUnwrap(URL(string: urlString))
        let gw = try XCTUnwrap(readOpenClawGatewayConfig(), "no ~/.openclaw/openclaw.json")

        let client = OpenClawWSClient()
        let stream = try await client.connect(url: url, token: gw.token)
        let connected = Flag()
        let drain = Task {
            for await event in stream {
                switch event {
                case .connected(let sid, let key):
                    print("LIVE[ws] connected sessionId=\(sid) sessionKey=\(key)")
                    connected.set()
                case .error(let e):
                    print("LIVE[ws] error: \(e)")
                case .disconnected(let reason):
                    print("LIVE[ws] disconnected: \(reason ?? "nil")")
                default:
                    break
                }
            }
            print("LIVE[ws] stream ended")
        }
        defer { drain.cancel() }
        let deadline = Date().addingTimeInterval(30)
        while !connected.get(), Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard connected.get() else {
            XCTFail("gateway handshake did not complete in 30s")
            return
        }

        // Unique per-run ids; seq base from wall clock keeps it monotonic
        // across runs without touching the app's persisted counter.
        let runID = "ctx-livetest-\(UUID().uuidString.prefix(8))"
        var seq = Int(Date().timeIntervalSince1970)
        let now = Date()
        let windowStart = now.addingTimeInterval(-60)
        let sw = AmbientSourceWindow(
            start: Int64(windowStart.timeIntervalSince1970 * 1000),
            end: Int64(now.timeIntervalSince1970 * 1000)
        )

        // Real events from the T2b extractor over synthetic transcripts.
        let drafts = AmbientSalientExtractor.extract(from: [
            "明日の14時にリリース計画の打ち合わせをしましょう",   // appointment, conf 0.7
            "例の資料、送っておきますね",                        // commitment, conf 0.55 (< 0.6 → no inject)
        ], now: now)
        XCTAssertEqual(drafts.count, 2, "extractor should yield appointment + commitment")
        let appointment = try XCTUnwrap(drafts.first { $0.eventType == "appointment" })
        let commitment = try XCTUnwrap(drafts.first { $0.eventType == "commitment" })

        func ingest(_ events: [AmbientSalientEvent], texts: [String], label: String) async throws -> [AmbientEventReceipt] {
            let params = AmbientIngestProducer.buildParams(
                segmentTexts: texts,
                windowStart: windowStart,
                windowEnd: now,
                sessionID: runID,
                sourceSeq: { seq += 1; return seq }(),
                now: now,
                events: events
            )
            let payload = try await client.request(method: "ambient.ingest", params: params)
            let receipts = payload?.events ?? []
            print("LIVE[\(label)] stateAccepted=\(payload?.stateAccepted ?? false) receipts=\(receipts.count)")
            for r in receipts { print("LIVE[\(label)]   \(receiptLine(r))") }
            return receipts
        }

        // (1) appointment + low-confidence commitment in one ingest.
        seq += 1; let apptSeq = seq
        let evA = makeEvent(appointment, seq: apptSeq, runID: runID, sw: sw)
        seq += 1
        let evB = makeEvent(commitment, seq: seq, runID: runID, sw: sw)
        let r1 = try await ingest([evA, evB], texts: ["release planning"], label: "1:new+lowconf")
        XCTAssertEqual(r1.count, 2, "expected per-event receipts")
        let apptReceipt = r1.first { $0.sourceEventId == evA.sourceEventId }
        let lowReceipt = r1.first { $0.sourceEventId == evB.sourceEventId }
        XCTAssertEqual(apptReceipt?.dedup, "new")
        XCTAssertNotEqual(lowReceipt?.status, "injected", "confidence<0.6 must not be injected")

        // (2) semantic re-send: same dedupKey, fresh sourceEventId → duplicate.
        seq += 1
        let evA2 = makeEvent(appointment, seq: seq, runID: runID, sw: sw)
        let r2 = try await ingest([evA2], texts: ["release planning restated"], label: "2:semantic-dup")
        XCTAssertEqual(r2.first?.dedup, "duplicate", "same dedupKey must fold as duplicate")

        // (3) sensitive event must not be injected.
        seq += 1
        let sensitiveDraft = try XCTUnwrap(AmbientSalientExtractor.extractOne(
            from: "明後日に検査結果の打ち合わせがある", now: now))
        let evS = makeEvent(sensitiveDraft, seq: seq, runID: runID, sw: sw, privacyFlags: ["sensitive"])
        let r3 = try await ingest([evS], texts: ["sensitive topic"], label: "3:sensitive")
        XCTAssertNotEqual(r3.first?.status, "injected", "sensitive must not be injected")

        // (4) transport idempotency: exact replay of evA (same sourceEventId)
        //     must return the same eventId.
        let r4 = try await ingest([evA], texts: ["release planning replay"], label: "4:idempotent-replay")
        if let original = apptReceipt?.eventId, let replay = r4.first?.eventId {
            XCTAssertEqual(original, replay, "same sourceEventId must return same eventId")
        } else {
            XCTFail("missing eventId in idempotency receipts")
        }

        await client.disconnect()
    }
}
